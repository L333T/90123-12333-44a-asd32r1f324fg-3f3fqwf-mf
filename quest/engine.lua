-- ============================================================================
-- Master Farmer - Grindbot
-- Quest engine - driven entirely by the RestedXP Guides addon. Never runs grind.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.253.0
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
local gamever = require("gamever")

local gossip = require("gossip")

local gui = require("gui")
local state = require("state")
local npc = require("quest/npc")
local rotation = require("rotation")
local targeting = require("targeting")
local movement = require("movement")
local healing = require("healing")
local geometry = require("geometry")
local guide = require("quest/guide")
local travel_routes = require("travel_routes")
local loot = nil
do
    local ok, mod = pcall(require, "loot")
    if ok and type(mod) == "table" then
        loot = mod
    end
end
local events = nil
do
    local ok, mod = pcall(require, "events")
    if ok and type(mod) == "table" then
        events = mod
    end
end

local quest = {}

local SCAN_GAP = 0.8          -- seconds between target scans
local KILL_TIMEOUT = 60.0     -- give up on one mob after this
local ARRIVE = 3.0            -- yards: standing on a waypoint
local TALK_REACH = 4.0        -- yards: close enough to interact
local TALK_SEARCH = 12.0      -- yards around the waypoint to look for a giver
local TALK_SEARCH_FAR = 40.0  -- yards: search from the door of a building
local TALK_ARRIVE = 8.0       -- yards: at the door is close enough to stop walking
local STEP_INSIDE = 6.0       -- yards toward the waypoint, at the player's height
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
local g_cur_kind = nil         -- 2.125.0: kind of the goal being worked
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
-- 2.204.0: a ".vendor" step's gossip -> vendor option tries on the current NPC.
-- 2.206.0 gsel: the guide file's gossip choice, made once per opened frame;
-- GOSSIP_AFTER: RestedXP's own gossip automation acts on GOSSIP_SHOW first.
-- (One table, 2.210.0: the chunk's 200-local limit.)
-- 2.215.0 gid: the goal's IDENTIFIED NPC (guide id / learned id / raid marker /
-- waypoint title / guide giver name, standing at the goal's waypoint) - tried =
-- its name once a dialog with one began, refused = { name, npc } once one of
-- them said the quest is not on offer. Cleared with the goal (reset_gid).
local TK = { vend = { guid = nil, tries = 0, next_t = 0 }, VEND_TRIES = 3, NPC_VENDOR = 0x80,
    gsel = { key = nil }, GOSSIP_AFTER = 1.0, gid = { tried = nil, refused = nil } }
local g_in_dialog = false      -- the last tick was spent on an NPC dialog goal
local g_in_travel = false      -- the last tick was spent walking to a waypoint
local TALK_DONE = 2.0         -- seconds a frame is left open before the goal counts
-- Every candidate NPC ruled out: when, so the list can be retried later.
local g_bad_since = 0
local BAD_GIVER_RETRY = 20.0
-- Where the bot was last sent to reach the giver, to re-route when it moves.
local g_giver_walk = nil

-- ARRIVAL IS FLAT (2.134.0). A RestedXP waypoint's height is the terrain
-- under it, and indoors that is the ground outside, not the floor the NPC
-- stands on: a 3D "within 3 yards" never came true inside a building, so the
-- bot circled the spot forever. Within ARRIVE_DZ of the guessed height is
-- arrival; beyond it, standing on the spot once navigation has stopped is.
local ARRIVE_DZ = 12

-- NO-PROGRESS CHECK (2.134.0). An accept / turn-in / talk goal that makes no
-- progress for STALL_AFTER seconds - no yard gained on the NPC, no dialog
-- stage advanced, no quest-log change - is recovered: frames closed, the
-- guide re-read, the giver searched for again and a fresh path requested.
-- STALL_MAX recoveries in a row skip the goal. The 5-minute watchdog stays
-- as the last line behind it.
local STALL_AFTER = 30.0
local STALL_MAX = 3
local STALL_GAIN = 2.0        -- yards closer that count as progress
local g_stall = { t = 0, seen = 0, best = nil, reach = false, npc_seq = nil, log = nil, recoveries = 0 }
local g_force_path = false    -- next walk drops the old path and asks for a new one

-- The NPC refused an interact (a UI error): close in before the next one.
local CLOSE_REACH = 2.5
local g_close_in = false

-- The NPC lists the quest as not complete: wait, then ask once more.
local NOT_READY_HOLD = 10.0
local NOT_READY_MAX = 2
local g_not_ready = 0
local g_hold_until = 0

-- An innkeeper for a ".home" goal: the bind option was selected.
local g_bind_asked = false
-- Talk goals: when the last interact went out.
local g_talk_interact_t = 0

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
local last_aim_x, last_aim_y = nil, nil
local last_road = nil
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
    -- Quest detail is part of "Detailed session log" (2.188.0).
    if not gui.is_on("session_detail") then
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
    if type(yards) ~= "number" or yards < 1 then
        yards = 30
    end
    return yards
end

--- Fight the current kill target. Returns false once there is nothing left to
--- fight - dead, gone, unreachable or timed out.
local APPROACH_BAND = 15       -- hand over to combat movement this far outside the engage distance
local APPROACH_WAIT = 3.0      -- 2.155.0: seconds an approach waits for its path leg
local g_appr = { guid = nil, since = 0, off = false, released = false }

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
    -- No way closer (behind a mountain): blacklisted, the guide goes on (2.230.0).
    if type(targeting.approach_stuck) == "function" and targeting.approach_stuck(player, unit, yards) then
        release_combat()
        state.set_note("Quest", "Skip unreachable")
        return false
    end
    -- FAR TARGET: WALK IN ON A PATH (2.139.0). Combat hops stall from 35 yd
    -- (00:52 log: no progress at 32 yd). Stay on the Sentinel walk until
    -- inside the GUI engage distance + APPROACH_BAND, then combat movement
    -- finishes the close.
    --
    -- NO RELEASE / RE-TAKE LOOP (2.155.0). This released combat movement
    -- (a stop), asked navigation for the leg - refused, the move gap after a
    -- stop had not passed - then fell through to combat_engage, which took
    -- COMBAT back and could not move for the same gap; next tick, release
    -- again. The 00:49 session stood 70 s at "engage Ragged Young Wolf", and
    -- the 01:00 one dropped three boars at 30-37 yd as "unreachable" with no
    -- "approaching" line. Now combat movement is released once per target,
    -- the approach waits APPROACH_WAIT for its leg instead of falling
    -- through, and only then is the target closed on by combat movement.
    local guid_a = safe(function() return unit:get_guid() end)
    if g_appr.guid ~= guid_a then
        g_appr.guid, g_appr.since, g_appr.off, g_appr.released = guid_a, now, false, false
    end
    -- 2.240.0: a gap since the last approach tick (a rest held the cascade)
    -- restarts the wait. Without it APPROACH_WAIT had run out during the rest
    -- and the first tick after it gave up the path - "no path leg ... closing
    -- directly" at a mob 64 yd away. Same target, so `off` is cleared too.
    if (now - (g_appr.seen or now)) > 1.0 then
        g_appr.since, g_appr.off = now, false
    end
    g_appr.seen = now
    if not g_appr.off and dist > (yards + APPROACH_BAND)
        and safe(function() return player:is_in_combat() end) ~= true then
        local up = safe(function() return unit:get_position() end)
        if up then
            if not g_appr.released and type(movement.in_combat_movement) == "function"
                and movement.in_combat_movement() and type(movement.combat_release) == "function" then
                movement.combat_release()
            end
            g_appr.released = true
            if type(movement.set_approach_target) == "function" then
                movement.set_approach_target(guid_a)
            end
            local walking = movement.is_moving()
                and not (type(movement.in_combat_movement) == "function" and movement.in_combat_movement())
            if walking or movement.nav_to(up) then
                if not walking then
                    trail("act", "approach %s on a path (%.0f yd)",
                        tostring(safe(function() return unit:get_name() end)), dist)
                end
                g_appr.since = now
                state.set_note("Quest", string.format("%s (approaching %d yd)", note or "Closing", math.floor(dist / 5) * 5))
                return true
            end
            if (now - g_appr.since) < APPROACH_WAIT then
                state.set_note("Quest", string.format("%s (approaching %d yd)", note or "Closing", math.floor(dist / 5) * 5))
                return true
            end
            g_appr.off = true
            local why = type(movement.last_fail_reason) == "function" and movement.last_fail_reason() or nil
            trail("act", "no path leg to %s in %.0fs (%s%s) - closing directly",
                tostring(safe(function() return unit:get_name() end)), APPROACH_WAIT,
                tostring(why or "no reason given"),
                (type(movement.in_combat_movement) == "function" and movement.in_combat_movement())
                    and ", combat movement owns" or "")
        end
    end
    -- Inside the approach band: combat movement owns it, the tag is done.
    if type(movement.set_approach_target) == "function" then
        movement.set_approach_target(nil)
    end
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
-- ON THE WAY TO AN NPC (2.216.0). In combat or being attacked while a
-- turn-in / accept / talk goal is being walked, the walk always waits and the
-- fight comes first:
--   * "being attacked" counts as combat - a mob targeting the player or the
--     pet (targeting.attackers) is fought even while the player's own combat
--     flag has dropped for a moment (a fled or evading mob coming back); the
--     flag alone used to hand the tick back to the walk then.
--   * in combat with nothing in view, the hold before walking on is
--     NPC_GOAL_HOLD s instead of targeting's 8 s.
-- (A field of the existing TK table: the chunk's 200-local limit.)
TK.NPC_GOAL = { turnin = true, accept = true, talk = true }
TK.NPC_GOAL_HOLD = 30.0

local function fight_back(player, label)
    local range = targeting.THREAT_RANGE or 40
    local cur_guid = (state.target.kind == "kill") and state.target.guid or nil
    local in_combat = safe(function() return player:is_in_combat() end) == true
    local attacked = type(targeting.attackers) == "function" and targeting.attackers(player) > 0
    local attacker = targeting.attacker_to_switch(player, cur_guid, range)
    if not attacker and attacked and not in_combat
        and not (state.target.kind == "kill" and type(targeting.engaged) == "function"
            and targeting.engaged(state.target.unit)) then
        -- attacker_to_switch reads the combat flag; the attack itself is the
        -- evidence here. Never while the current kill is being fought (2.226.0).
        attacker = targeting.nearest(player, targeting.threats(player, range))
        if attacker and cur_guid ~= nil
            and safe(function() return attacker:get_guid() end) == cur_guid then
            attacker = nil                   -- already on it: step 2 keeps fighting it
        end
    end
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
    if not in_combat and not attacked then
        targeting.combat_hold(player)        -- resets the hold window
        return false
    end
    local nearest = targeting.nearest(player, targeting.threats(player, range))
    if nearest then
        targeting.combat_active()
        engage(player, nearest, "Guide: defending")
        return true
    end
    local npc_goal = TK.NPC_GOAL[g_cur_kind or ""] == true
    if targeting.combat_hold(player, npc_goal and TK.NPC_GOAL_HOLD or nil) then
        movement.nav_stop()
        state.set_note("Quest", npc_goal and ("Guide: in combat - " .. tostring(g_cur_kind) .. " waits")
            or "Guide: holding - combat not over")
        return true
    end
    return false
end

-- KILL MOBS ON THE WAY was removed in 2.188.0 with its Questing-tab box.
-- Mobs that attack are still fought (fight_back), and "Grind to XP" steps
-- still pull the nearest XP-worthy enemy (xp_goal, nearest_xp_enemy below).

local XP_GREY_GAP = 5
local CRITTER_TYPE = nil
local function xp_critter(u)
    if CRITTER_TYPE == nil then
        local ok, enums = pcall(require, "common/enums")
        CRITTER_TYPE = (ok and type(enums) == "table" and type(enums.creature_type) == "table"
            and enums.creature_type.CRITTER) or false
    end
    if not CRITTER_TYPE then return false end
    return safe(function() return u:get_creature_type() end) == CRITTER_TYPE
end

--- The nearest enemy within `range` worth XP (2.158.0): no critters, no greys.
local function nearest_xp_enemy(player, range)
    local list = targeting.find_mobs(player, nil, range, true)
    local keep = {}
    local my_level = safe(function() return player:get_level() end) or 1
    for i = 1, #(list or {}) do
        local u = list[i]
        local lvl = safe(function() return u:get_level() end) or my_level
        if not xp_critter(u) and lvl >= my_level - XP_GREY_GAP then
            keep[#keep + 1] = u
        end
    end
    local unit = targeting.nearest(player, keep)
    local d = unit and safe(function() return player:distance_to(unit) end) or nil
    return unit, d
end

local CHAIN_WP = 12

local function approach_kind()
    local kind = g_cur_kind
    if kind == "accept" or kind == "turnin" or kind == "talk" or kind == "fly" then
        return "npc"
    end
    if kind == "kill" or kind == "collect" or kind == "xp" then
        return "enemy"
    end
    return nil
end

--- Standing within `yards` of `pos`, measured flat (see ARRIVE_DZ).
local function near(pos, yards)
    local me = safe(function() return izi.me():get_position() end)
    if not me or not pos then
        return false
    end
    local d = geometry.distance_flat(me, pos)
    if type(d) ~= "number" or d > yards then
        return false
    end
    if type(me.z) ~= "number" or type(pos.z) ~= "number" or math.abs(me.z - pos.z) <= ARRIVE_DZ then
        return true
    end
    return not movement.is_moving()
end

local function walk_to(pos, note, arrive)
    arrive = arrive or ARRIVE
    if near(pos, arrive) then
        return false
    end
    -- Movement treats 5 yards as arrived and stops. Asking it for another
    -- 2 yards at a building door is the stall both Kharanos sessions showed:
    -- "no progress toward the nav for 4s (7 yd) - steering".
    if arrive >= TALK_ARRIVE then
        local me = safe(function() return izi.me():get_position() end)
        local d = me and geometry.distance_flat(me, pos)
        if type(d) == "number" and d <= TALK_ARRIVE then
            return false
        end
    end
    if g_force_path then
        -- A stall recovery: whatever path is running got the bot nowhere.
        g_force_path = false
        movement.nav_stop()
        last_walk_x, last_walk_y, last_aim_x, last_aim_y = nil, nil, nil, nil
    end
    -- Only when the destination moves to a new yard: formatting the line
    -- every frame just to have errorlog throw it away is what this avoids.
    local wx, wy = math.floor(pos.x), math.floor(pos.y)
    local moved = wx ~= last_walk_x or wy ~= last_walk_y
    if moved then
        last_walk_x, last_walk_y = wx, wy
        local me = safe(function() return izi.me():get_position() end)
        trail("walk", "to (%.0f, %.0f, %.0f) %.0fy away for %s", pos.x, pos.y, pos.z,
            me and geometry.distance(me, pos) or -1, tostring(note))
    end
    if movement.is_blocked(pos) or movement.last_fail_offmesh() then
        movement.clear_fail()
        local me = safe(function() return izi.me():get_position() end)
        local d = me and geometry.distance_flat(me, pos)
        -- Close enough to search for the NPC instead of walking forever.
        if type(d) == "number" and d <= TALK_SEARCH_FAR then
            return false
        end
        state.set_note("Quest", "Guide: cannot reach " .. note)
        return true
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        state.set_note("Quest", "Nav settle")
        return true
    end
    state.set_note("Quest", "Guide: " .. note)
    g_in_travel = true
    -- A destination on a recorded inn or flight-path road is walked as the
    -- next point of that road. The real waypoint stays the arrival test.
    local me = safe(function() return izi.me():get_position() end)
    local hop = me and travel_routes.hop(me, pos) or nil
    local target = hop or pos
    if travel_routes.road ~= last_road then
        last_road = travel_routes.road
        if last_road then
            trail("walk", "recorded road %s toward %s", last_road, tostring(note))
        end
    end
    local tx = math.floor(target.x or 0)
    local ty = math.floor(target.y or 0)
    local aim_moved = tx ~= last_aim_x or ty ~= last_aim_y
    if aim_moved then
        last_aim_x, last_aim_y = tx, ty
    end
    if type(movement.keep_path) == "function" then
        movement.keep_path(true)
    end
    if type(movement.set_approach) == "function" then
        -- A short road hop is not "closing on the NPC". Wall checks still run.
        -- The last yards use the real destination, so the NPC approach returns.
        local approach = approach_kind()
        if hop then approach = nil end
        movement.set_approach(approach)
    end
    if movement.is_moving() then
        -- The arrow moved, the next waypoint is up, or the road point advanced.
        -- One retarget, no stop.
        if (moved or aim_moved) and type(movement.nudge) == "function" then
            movement.nudge(target)
        end
    else
        movement.nav_to(target, true)
    end
    return true
end

--- The quest title the NPC's frames will list, for selecting it.
---
--- The quest log has it for a turnin. An accept is not in the log yet, so the
--- guide line is used with its verb stripped; quest/npc also takes a lone
--- entry without any title match, which covers most givers.
local function quest_title(goal, kind, qid)
    qid = qid or goal.quest_id
    local title = qid and guide.log_title(qid) or nil
    if title then
        return title
    end
    -- A multi-quest goal's line names several quests: no single title.
    if qid ~= goal.quest_id then
        return nil
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

-- ----------------------------------------------------------------------------
-- BUY STEPS (2.167.0)
-- ----------------------------------------------------------------------------
-- RestedXP ".buy" ("Buy 2 stacks of Light Shot") was mapped to "collect",
-- which went looking for a mob to kill. Now: the item name and amount are
-- read from the goal text, the bot walks to the step's waypoint, opens the
-- vendor there (the waypoint's named NPC, else the nearest NPC flagged
-- vendor), finds the item on the vendor by name and buys until the bags hold
-- the amount. buy_item's quantity is measured, not assumed: the first
-- purchase is one unit, and what arrives decides the size of the next.
-- Vendor item info does not exist on WoW Forever - the step is skipped there.
local BUY_TIMEOUT = 120
local BUY_GAP = 0.9
local BUY_TALK_GAP = 1.5
local BUY_FAILS = 3
local g_buy = { key = nil }
-- Known ids (2.169.0): the bags are counted before walking to a vendor, so a
-- step already done is not walked to. Lower-case name -> item id.
local BUY_IDS = {
    ["light shot"] = 2516, ["rough arrow"] = 2512, ["sharp arrow"] = 2515, ["heavy shot"] = 2519,
    ["small ammo pouch"] = 2102, ["light quiver"] = 2101,
}

local function strip_codes(t)
    t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cRXP_[%u_]-_", ""):gsub("|r", ""):gsub("|T.-|t", "")
    t = t:gsub("[%[%]]", "")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- item name, stacks (or nil), count (or nil) from "Buy 2 stacks of X" /
--- "Buy 20 X" / "Buy X".
local function parse_buy(text)
    if type(text) ~= "string" then return nil end
    local t = strip_codes(text)
    -- 2.191.0: "Buy and equip a [Small Throwing Knife]" (a RestedXP vendor
    -- step) is a buy of ONE item; equip.lua wears it once the window closes.
    t = t:gsub("^([Bb]uy)%s+and%s+equip%s+", "%1 ")
    local one = t:match("^[Bb]uy%s+an?%s+(.+)$")
    if one then return one, nil, 1 end
    local n, name = t:match("^[Bb]uy%s+(%d+)%s+stacks?%s+of%s+(.+)$")
    if n then return name, tonumber(n), nil end
    n, name = t:match("^[Bb]uy%s+(%d+)x?%s+(.+)$")
    if n then return name, nil, tonumber(n) end
    name = t:match("^[Bb]uy%s+(.+)$")
    if name then return name, 1, nil end
    return nil
end

local function vendor_find(name)
    local want = string.lower(name)
    local n = safe(function() return core.game_ui.get_vendor_item_count() end) or 0
    local best = nil
    for i = 1, n do
        local info = safe(function() return core.game_ui.get_vendor_item_info(i) end)
        local iname = type(info) == "table" and type(info.item_name) == "string" and string.lower(info.item_name) or nil
        if iname and iname ~= "" then
            if iname == want then return i, info end
            if not best and (iname:find(want, 1, true) or want:find(iname, 1, true)) then best = { i, info } end
        end
    end
    if best then return best[1], best[2] end
    return nil
end

local function bag_count(item_id)
    local ok_b, bags = pcall(require, "bags")
    if not ok_b or type(bags) ~= "table" or type(bags.count) ~= "function" then return 0 end
    return bags.count(item_id) or 0
end

local function merchant_up()
    local ok_v, vendor = pcall(require, "vendor")
    return ok_v and type(vendor) == "table" and type(vendor.merchant_open) == "function" and vendor.merchant_open() == true
end

local function buy_vendor_unit(player, wps)
    for i = 1, #wps do
        local title = wps[i].title
        if title then
            local u = targeting.find_named(player, title, nil, 60)
            if u and not g_buy.bad[safe(function() return u:get_guid() end) or ""] then return u end
        end
    end
    local list = targeting.visible_objects and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true then
            local f = safe(function() return u:get_npc_flags() end)
            local g = safe(function() return u:get_guid() end)
            if type(f) == "number" and math.floor(f / 0x80) % 2 == 1 and not g_buy.bad[g or ""] then
                local d = safe(function() return player:distance_to(u) end)
                if type(d) == "number" and d <= 60 and (best_d == nil or d < best_d) then best, best_d = u, d end
            end
        end
    end
    return best
end

local function buy_done(goal, why)
    trail("act", "buy step: %s", why)
    pcall(function() core.input.close_merchant() end)
    g_buy = { key = nil }
    local ok_e, equip = pcall(require, "equip")
    if ok_e and type(equip) == "table" and type(equip.invalidate) == "function" then
        pcall(equip.invalidate)
    end
    guide.mark_goal_done(guide.step_num(), goal.index)
    return true
end

-- ITEM STEPS (2.209.0) - RestedXP ".destroy <item>" and ".equip <slot>,<item>".
-- Both gate their step (RXPGuides functions.lua): .destroy until the item is
-- gone from the bags, .equip (with text) until that item is in that slot. The
-- bot walked to the waypoint and waited. The item comes from the goal text's
-- [name] through data/rxp_targets M.items; the API's container calls do the
-- work (destroy_container_item, equip_container_item). The Hearthstone is
-- never destroyed - vendor trips hearth home.
-- One file-level table (2.210.0): quest/engine.lua sits at Lua's limit of
-- 200 locals in a chunk - 2.209.0 crossed it and the file stopped compiling.
local IS = { step = { key = nil, t = 0, tries = 0 }, GAP = 1.0, TRIES = 5, NEVER_DESTROY = { [6948] = true } }

function IS.equipped_id(player, slot)
    local info = safe(function() return player:get_item_at_inventory_slot(slot) end)
    local obj = type(info) == "table" and info.object or nil
    return obj and safe(function() return obj:get_item_id() end) or nil
end

function IS.goal(player, goal, label)
    local a = type(goal.action) == "string" and string.lower(goal.action) or ""
    if a ~= "destroy" and a ~= "equip" then return false end
    if type(guide.rxp_item_for) ~= "function" then return false end
    local rec = guide.rxp_item_for(goal.text or label)
    if not rec then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    local now = izi.now()
    if IS.step.key ~= g_key then IS.step = { key = g_key, t = 0, tries = 0 } end
    local s = IS.step
    local ok_b, bags = pcall(require, "bags")
    local list = ok_b and type(bags) == "table" and bags.list(player) or {}
    local entry = nil
    for i = 1, #list do
        if list[i].item_id == rec.id then entry = list[i] break end
    end
    if a == "equip" and rec.slot and IS.equipped_id(player, rec.slot) == rec.id then
        trail("act", "equip step: item %d already in slot %d", rec.id, rec.slot)
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if not entry or (a == "destroy" and IS.NEVER_DESTROY[rec.id]) or s.tries >= IS.TRIES then
        trail("act", "%s step: item %d %s - next goal", a, rec.id,
            not entry and "not in the bags" or (IS.NEVER_DESTROY[rec.id] and "is kept (Hearthstone)" or "would not move"))
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if (now - s.t) < IS.GAP then return true end
    s.t, s.tries = now, s.tries + 1
    movement.nav_stop()
    if a == "destroy" then
        local done = safe(function() return core.input.destroy_container_item(entry.bag, entry.slot) end) == true
        trail("act", "destroy step: item %d (bag %d slot %d) %s", rec.id, entry.bag, entry.slot,
            done and "deleted" or "refused")
        state.set_note("Quest", "Guide: deleting " .. tostring(label))
    else
        local slot = rec.slot or 16
        local done = safe(function() return core.input.equip_container_item(entry.bag, entry.slot, slot) end) == true
        if not done then
            -- A bind-on-equip prompt holds the item; answer it (equip.lua does the same).
            local pending = safe(function() return core.game_ui.get_pending_equip_slot() end)
            if type(pending) == "number" and pending > 0 then
                pcall(function() core.input.equip_pending_item(pending) end)
            end
        end
        trail("act", "equip step: item %d into slot %d %s", rec.id, slot, done and "sent" or "pending / refused")
        local ok_e, eq = pcall(require, "equip")
        if ok_e and type(eq) == "table" and type(eq.invalidate) == "function" then pcall(eq.invalidate) end
        state.set_note("Quest", "Guide: equipping " .. tostring(label))
    end
    return true
end

--- Drive a ".buy" goal. True while it holds the tick.
local function buy_goal(player, goal, wps, label)
    local a = type(goal.action) == "string" and string.lower(goal.action) or ""
    if a ~= "buy" then
        -- 2.191.0: a ".vendor" step reading "Buy and equip a [X]" was only
        -- talked to - nothing bought, RestedXP never moved on.
        if a ~= "vendor" or not parse_buy(goal.text or label) then return false end
    end
    local now = izi.now()
    if g_buy.key ~= g_key then
        local name, stacks, count = parse_buy(goal.text or label)
        if not name then return false end
        g_buy = { key = g_key, name = name, stacks = stacks, count = count, since = now,
            item_id = BUY_IDS[string.lower(name)], target = nil, unit_per_call = nil, pending = nil, fails = 0,
            talk_t = -1e9, bad = {} }
        if g_buy.item_id then
            local lname = string.lower(name)
            local per = (lname:find("shot", 1, true) or lname:find("arrow", 1, true)) and 200 or 1
            g_buy.target = count or ((stacks or 1) * per)
        end
        trail("act", "buy step: %s x%s", name, stacks and (tostring(stacks) .. " stack(s)") or tostring(count or 1))
    end
    local b = g_buy
    if gamever.is_forever() then
        return buy_done(goal, "vendor items cannot be read on WoW Forever - skipped")
    end
    if (now - b.since) > BUY_TIMEOUT then
        return buy_done(goal, "gave up after " .. BUY_TIMEOUT .. " s")
    end
    if b.item_id and b.target and bag_count(b.item_id) >= b.target then
        return buy_done(goal, string.format("have %d %s", bag_count(b.item_id), b.name))
    end

    if merchant_up() then
        movement.nav_stop()
        local idx, info = vendor_find(b.name)
        if not idx then
            local u = state.target and state.target.unit
            local g = u and safe(function() return u:get_guid() end)
            if g then b.bad[g] = true end
            trail("act", "buy step: this vendor does not sell %s - trying another", b.name)
            pcall(function() core.input.close_merchant() end)
            return true
        end
        if not b.target then
            b.item_id = info.item_id
            local lot = (type(info.quantity) == "number" and info.quantity > 0) and info.quantity or 1
            -- A stack of ammo is 200; anything else sold by the lot counts the lot.
            local per_stack = (lot > 1) and math.max(lot, 20) or 20
            if lot >= 100 or b.name:lower():find("shot", 1, true) or b.name:lower():find("arrow", 1, true) then
                per_stack = 200
            end
            b.lot = lot
            b.target = b.count or ((b.stacks or 1) * per_stack)
            trail("act", "buy step: %s is vendor item %d (id %s, %d per purchase, %dc) - want %d",
                b.name, idx, tostring(b.item_id), lot, info.cost or 0, b.target)
        end
        local have = bag_count(b.item_id)
        if b.pending then
            if (now - b.pending.t) < BUY_GAP then return true end
            local got = have - b.pending.before
            if got > 0 then
                if not b.unit_per_call then b.unit_per_call = got / b.pending.q end
                b.fails = 0
            else
                b.fails = b.fails + 1
            end
            b.pending = nil
            if b.fails >= BUY_FAILS then
                return buy_done(goal, string.format("the vendor would not sell %s (gold %s)", b.name,
                    tostring(safe(function() return core.inventory.get_gold() end))))
            end
        end
        if have >= b.target then
            return buy_done(goal, string.format("have %d %s", have, b.name))
        end
        local cost = type(info.cost) == "number" and info.cost or 0
        local gold = safe(function() return core.inventory.get_gold() end) or 0
        if cost > 0 and gold < cost then
            return buy_done(goal, string.format("not enough gold for %s (%dc, have %dc)", b.name, cost, gold))
        end
        local q = 1
        if b.unit_per_call and b.unit_per_call > 0 then
            q = math.ceil((b.target - have) / b.unit_per_call)
            local per_call_cap = (b.unit_per_call <= 1) and 200 or 1
            q = math.max(1, math.min(q, per_call_cap))
            if cost > 0 then q = math.max(1, math.min(q, math.floor(gold / cost))) end
        end
        b.pending = { before = have, q = q, t = now }
        trail("act", "buy step: buy_item(%d, %d) - %d/%d %s", idx, q, have, b.target, b.name)
        pcall(function() core.input.buy_item(idx, q) end)
        state.set_note("Quest", string.format("Guide: buying %s  %d/%d", b.name, have, b.target))
        return true
    end

    -- Not at the vendor yet: find it at the waypoint and open it.
    local unit = buy_vendor_unit(player, wps)
    if not unit then
        if #wps > 0 then
            if g_move > #wps then g_move = 1 end
            if walk_to(wps[g_move].pos, label, TALK_ARRIVE) then return true end
        end
        state.set_note("Quest", "Guide: looking for the vendor - " .. tostring(label))
        return true
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > 5 then
        local up = safe(function() return unit:get_position() end)
        if up and walk_to(up, label, 4) then return true end
    end
    movement.nav_stop()
    if (now - b.talk_t) >= BUY_TALK_GAP then
        b.talk_t = now
        targeting.set_current(unit, "vendor")
        pcall(function() core.input.interact_with_object(unit) end)
        if gossip.is_open() then
            gossip.select({ icon = "VENDOR", icon_num = 1, type = "vendor",
                words = { "browse your goods", "let me browse", "your wares", "buy from you" } })
        end
    end
    state.set_note("Quest", "Guide: opening the vendor for " .. tostring(b.name))
    return true
end

-- QUEST TRAINER STEPS (2.149.0). The state of the train goal in progress.
local TRAIN_WAIT = 20          -- seconds at the waypoint with no trainer before moving on
local STEP_RETRY = 30          -- 2.150.0: seconds on "step complete" (our marks only) before retrying
local g_complete_since = 0
local g_train = { key = nil, at_wp = 0 }

local function is_train_action(goal)
    local a = type(goal.action) == "string" and string.lower(goal.action) or ""
    return a == "train" or a == "trainer"
end

-- PROFESSION TRAINER STEPS (2.191.0). "Train [Mining]" is a ".trainer" step
-- too, but the class trainer does not teach it: the bot looked 20 s for a
-- class trainer, marked the goal, RestedXP never moved on and it retried
-- every 30 s for good ("Train [Blacksmithing]" was even "done" at the rogue
-- trainer). Now a profession step goes to a profession trainer (the
-- waypoint's title, else the nearest unit flagged 0x40 profession trainer),
-- opens its window and buys that profession's service. trainer.lua is held
-- off meanwhile so it does not spend at a profession window.
local PROFESSIONS = {
    mining = true, blacksmithing = true, herbalism = true, skinning = true, engineering = true,
    alchemy = true, tailoring = true, leatherworking = true, enchanting = true, jewelcrafting = true,
    ["first aid"] = true, cooking = true, fishing = true,
}
local NPC_PROF_TRAINER = 0x40
local PROF_TIMEOUT = 60         -- seconds for the whole profession step
local PROF_TALK_GAP = 2.5
local PROF_VERIFY = 1.5
local g_prof = { key = nil }
local g_prof_failed = {}        -- profession -> true: gave up this session, no re-walk on retry

--- The profession a train goal names ("Train [Mining]" -> "mining"), or nil.
local function goal_profession(goal, label)
    local t = type(goal.text) == "string" and goal.text or label
    if type(t) ~= "string" then return nil end
    t = string.lower(strip_codes(t))
    local name = t:match("^train%s+(.+)$") or t
    name = name:gsub("^apprentice%s+", ""):gsub("%s+$", "")
    if PROFESSIONS[name] then return name end
    return nil
end

local function prof_hold(on)
    local ok_x, tx = pcall(require, "trainer")
    if ok_x and type(tx) == "table" and type(tx.hold) == "function" then tx.hold(on) end
end

local function prof_done(goal, prof, why, failed)
    trail("quest", "profession step (%s): %s", prof, why)
    if failed then g_prof_failed[prof] = true end
    pcall(function() core.quests.close_trainer() end)
    pcall(function() core.quests.close_gossip() end)
    prof_hold(false)
    g_prof = { key = nil }
    guide.mark_goal_done(guide.step_num(), goal.index)
    return true
end

local function prof_has_flag(v)
    return type(v) == "number" and v > 0 and math.floor(v / NPC_PROF_TRAINER) % 2 == 1
end

local function prof_trainer_unit(player, wps, bad)
    for i = 1, #wps do
        local title = wps[i].title
        if type(title) == "string" and title ~= "" then
            local u = targeting.find_named(player, title, nil, 80)
            if u and not bad[safe(function() return u:get_guid() end) or ""] then return u end
        end
    end
    local list = targeting.visible_objects and targeting.visible_objects() or nil
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_player() end) ~= true
            and prof_has_flag(safe(function() return u:get_npc_flags() end))
            and safe(function() return player:can_attack(u) end) ~= true then
            local g = safe(function() return u:get_guid() end)
            local d = safe(function() return player:distance_to(u) end)
            if not bad[g or ""] and type(d) == "number" and d <= 60 and (best_d == nil or d < best_d) then
                best, best_d = u, d
            end
        end
    end
    return best
end

--- The open trainer window's row for this profession: (index, available, cost) or nil.
local function prof_service(prof)
    local n = safe(function() return core.quests.get_num_trainer_services() end) or 0
    if type(n) ~= "number" then return nil end
    for i = 1, math.min(n, 400) do
        local info = safe(function() return core.quests.get_trainer_service_info(i) end)
        local sname = type(info) == "table" and type(info.spell_name) == "string" and string.lower(info.spell_name) or ""
        if sname == prof then
            local cat = type(info.category) == "string" and string.lower(info.category) or ""
            local c = safe(function() return core.quests.get_trainer_service_cost(i) end)
            local cost = type(c) == "table" and type(c.service_cost) == "number" and c.service_cost or 0
            return i, (cat == "" or cat == "available"), cost
        end
    end
    return nil
end

--- Drive a profession ".trainer" goal. True while it holds the tick.
local function prof_goal(player, goal, wps, label)
    if not is_train_action(goal) then
        if g_prof.key then prof_hold(false) g_prof = { key = nil } end
        return false
    end
    local prof = goal_profession(goal, label)
    if not prof then
        if g_prof.key then prof_hold(false) g_prof = { key = nil } end
        return false
    end
    local now = izi.now()
    if g_prof.key ~= g_key then
        g_prof = { key = g_key, since = now, talk_t = -1e9, bad = {}, pending = nil, opened = nil }
        if g_prof_failed[prof] then
            return prof_done(goal, prof, "no profession trainer earlier this session - skipped")
        end
        prof_hold(true)
        trail("quest", "profession step: looking for a %s trainer for %s", prof, tostring(label))
    end
    local p = g_prof
    if (now - p.since) > PROF_TIMEOUT then
        return prof_done(goal, prof, "gave up after " .. PROF_TIMEOUT .. " s", true)
    end

    local n_serv = safe(function() return core.quests.get_num_trainer_services() end) or 0
    if type(n_serv) == "number" and n_serv > 0 then
        movement.nav_stop()
        p.opened = p.opened or now
        pcall(function() core.skill.expand_trainer_skill_line(0) end)
        local idx, avail, cost = prof_service(prof)
        if p.pending then
            if (now - p.pending) < PROF_VERIFY then return true end
            p.pending = nil
            if not idx or not avail then
                return prof_done(goal, prof, "learned")
            end
            return prof_done(goal, prof, "the trainer would not teach it (gold "
                .. tostring(safe(function() return core.inventory.get_gold() end)) .. ")", true)
        end
        if not idx then
            -- The window lists other things (another profession's trainer,
            -- or rows still loading): give it a moment, then try another NPC.
            if (now - p.opened) < 2 then return true end
            local u = state.target and state.target.unit
            local g = u and safe(function() return u:get_guid() end)
            if g then p.bad[g] = true end
            trail("quest", "profession step: this trainer does not teach %s - trying another", prof)
            pcall(function() core.quests.close_trainer() end)
            p.opened = nil
            return true
        end
        if not avail then
            return prof_done(goal, prof, "already known (or not offered yet)")
        end
        local gold = safe(function() return core.inventory.get_gold() end) or 0
        if cost > 0 and gold < cost then
            return prof_done(goal, prof, string.format("not enough gold (%dc, have %dc)", cost, gold), true)
        end
        trail("quest", "profession step: buying %s (service %d, %dc)", prof, idx, cost)
        pcall(function() core.quests.buy_trainer_service(idx) end)
        p.pending = now
        state.set_note("Quest", "Guide: learning " .. prof)
        return true
    end
    p.opened = nil

    local unit = prof_trainer_unit(player, wps, p.bad)
    if not unit then
        if #wps > 0 then
            if g_move > #wps then g_move = 1 end
            if walk_to(wps[g_move].pos, label, TALK_ARRIVE) then return true end
        end
        state.set_note("Quest", "Guide: looking for the " .. prof .. " trainer")
        return true
    end
    local d = safe(function() return player:distance_to(unit) end) or 99
    if d > 5 then
        local up = safe(function() return unit:get_position() end)
        if up and walk_to(up, label, 4) then return true end
    end
    movement.nav_stop()
    if (now - p.talk_t) >= PROF_TALK_GAP then
        p.talk_t = now
        targeting.set_current(unit, "trainer")
        if gossip.is_open() then
            if not gossip.select({ icon = "TRAINER", icon_num = 3, type = "trainer",
                    words = { "train", "teach", "learn" } }) then
                local g = safe(function() return unit:get_guid() end)
                if g then p.bad[g] = true end
                trail("quest", "profession step: %s offers no training - trying another",
                    tostring(safe(function() return unit:get_name() end)))
                pcall(function() core.quests.close_gossip() end)
            end
        else
            pcall(function() core.input.interact_with_object(unit) end)
        end
    end
    state.set_note("Quest", "Guide: opening the " .. prof .. " trainer")
    return true
end

--- Drive a ".train" / ".trainer" goal. True while it holds the tick.
local function train_goal(player, goal, wps, label)
    if goal_profession(goal, label) then return false end
    if not is_train_action(goal) then
        if g_train.key then
            g_train.key = nil
            local ok_x, tx = pcall(require, "trainer")
            if ok_x and type(tx) == "table" and type(tx.quest_visit) == "function" then
                tx.quest_visit(false)
            end
        end
        return false
    end
    local ok_tr, tr = pcall(require, "trainer")
    if not ok_tr or type(tr) ~= "table" or type(tr.quest_visit) ~= "function" then
        return false
    end
    if gui.is_on("train") ~= true then
        trail("quest", "trainer goal skipped - Train Spells is off")
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if g_train.key ~= g_key then
        g_train.key, g_train.at_wp = g_key, 0
        local title = nil
        for i = 1, #wps do
            if type(wps[i].title) == "string" and wps[i].title ~= "" then title = wps[i].title break end
        end
        -- 2.206.0: the guide file's ".trainer <npc>" id, when it names one.
        local st = type(guide.rxp_step_for) == "function" and guide.rxp_step_for(wps) or nil
        local tid = st and st.t or nil
        tr.quest_visit(false)
        tr.quest_visit(true, title, tid)
        trail("quest", "trainer step: visiting the class trainer for %s%s%s", tostring(label),
            title and (" (" .. title .. ")") or "", tid and (" npc " .. tostring(tid)) or "")
    end
    if tr.quest_visit_done() then
        trail("quest", "trainer step done - %s", tostring(label))
        tr.quest_visit(false)
        g_train.key = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    -- trainer.tick runs earlier in the cascade and walks to / talks to a
    -- trainer in sight; while it does, the quest engine waits.
    if (type(tr.busy) == "function" and tr.busy()) or tr.in_sight(player) then
        state.set_note("Quest", "Guide: training - " .. tostring(label))
        return true
    end
    -- No trainer in sight yet: walk the step's waypoints.
    if #wps > 0 then
        if g_move > #wps then g_move = 1 end
        if walk_to(wps[g_move].pos, label, TALK_ARRIVE) then
            g_train.at_wp = 0
            return true
        end
    end
    local now = izi.now()
    if g_train.at_wp == 0 then g_train.at_wp = now end
    if (now - g_train.at_wp) >= TRAIN_WAIT then
        trail("quest", "trainer step: no class trainer found in %ds - next goal", TRAIN_WAIT)
        tr.quest_visit(false)
        g_train.key = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    state.set_note("Quest", "Guide: looking for the trainer - " .. tostring(label))
    return true
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

local function npc_id_of_unit(u)
    local id = u and safe(function() return u:get_npc_id() end) or nil
    if type(id) == "number" and id > 0 then return id end
    return nil
end
local g_giver_learned = nil   -- 2.185.0: { kind, qid, npc, text } when the giver came from a learned id

local function bad(unit)
    local g = unit and safe(function() return unit:get_guid() end)
    return g ~= nil and g_bad_givers[g] == true
end

-- AT THE GOAL (2.215.0). A name, a learned id or the player's target only
-- identifies the NPC when it stands at the goal's waypoint - RestedXP's
-- .goto for a dialog step is the NPC's own spot. Searched around the PLAYER,
-- a turn-in picked Grelin Whitebeard 6 yd away while the guide pointed
-- 200 yd off. No waypoint: anywhere in range, as before.
local function at_goal(unit, wps)
    if #wps == 0 then return true end
    local up = safe(function() return unit:get_position() end)
    if not up then return false end
    for i = 1, #wps do
        local p = wps[i].pos
        local d = p and geometry.distance_flat(up, p)
        if type(d) == "number" and d <= TALK_SEARCH_FAR then return true end
    end
    return false
end

local function find_giver(player, goal, kind, wps, qid)
    qid = qid or goal.quest_id
    -- THE GUIDE FILE'S NPC (2.206.0): a ".vendor <npc>" / ".trainer <npc>"
    -- step names its NPC by id (data/rxp_targets M.steps, matched by the
    -- step's waypoint). Ids work where names do not (blank on WoW Forever).
    local a = string.lower(goal.action or "")
    if (a == "vendor" or a == "trainer") and type(guide.rxp_step_for) == "function" then
        local st = guide.rxp_step_for(wps)
        local id = st and ((a == "vendor" and st.v) or (a == "trainer" and st.t)) or nil
        if id then
            local unit = targeting.find_npc(player, id, 80)
            if unit and not bad(unit) and at_goal(unit, wps) then
                return unit, "guide npc id " .. tostring(id)
            end
        end
    end
    local known = guide.known_quest_npc(kind, qid, goal.text)
    if known then
        local unit = targeting.find_npc(player, known, 80)
        -- A learned NPC that is no quest giver (a vendor, 2.185.0) was learned
        -- wrongly: forget it and find the giver the usual way.
        if unit and guide.gives_quests(unit) == false then
            trail("act", "learned npc %d for quest %s gives no quests - forgotten", known, tostring(goal.quest_id))
            guide.forget_quest_npc(kind, goal.quest_id, known, goal.text)
            unit = nil
        end
        if unit and not bad(unit) and at_goal(unit, wps) then
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
            if unit and not bad(unit) and at_goal(unit, wps) then
                return unit, "waypoint title '" .. title .. "'"
            end
        end
    end
    -- The friendly NPCs the guide files pair with this quest (2.206.0,
    -- data/rxp_targets): since 2.215.0 by role - M.givers for an accept,
    -- M.takers for a turn-in - and only the one at the goal's waypoint.
    if (kind == "accept" or kind == "turnin") and type(guide.rxp_quest_givers) == "function" then
        local names = guide.rxp_quest_givers(qid, kind)
        for i = 1, #names do
            local unit = targeting.find_named(player, names[i], nil, 80)
            if unit and not bad(unit) and at_goal(unit, wps) then
                return unit, "guide giver '" .. names[i] .. "'"
            end
        end
    end
    -- NO GUESSING AFTER THE RIGHT NPC (2.215.0). Once the goal's identified
    -- NPC has been talked to, the nearest-unit fallbacks below have no
    -- evidence behind them: the 12:14 log walked from Durnan Furcutter (the
    -- guide's giver, "not offered") through eight Anvilmar NPCs - trainers,
    -- vendors, a guard - three tries each. dialog_goal decides what a refusal
    -- by the identified NPC means.
    if TK.gid.tried then
        return nil, nil
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
                local td = p and geometry.distance_flat(tp, p)
                if type(td) == "number" and td <= TALK_SEARCH_FAR then
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
        local unit = guide.nearest_talkable(player, TALK_SEARCH, wps[i].pos, g_bad_givers, kind == "accept" or kind == "turnin")
        if unit then
            return unit, "nearest at waypoint"
        end
    end
    if #wps == 0 then
        local unit = guide.nearest_talkable(player, TALK_SEARCH, nil, g_bad_givers, kind == "accept" or kind == "turnin")
        if unit then
            return unit, "nearest"
        end
    end
    return nil, nil
end

--- A goal changed: if the previous one was a dialog the bot drove and it
--- landed, record the NPC as that quest's giver or taker.
local function commit_pending()
    -- The goal's identified-NPC state goes with the goal (2.215.0). Reset here,
    -- not in tick_inner's goal-change block that calls this (2.218.0): one more
    -- upvalue there (TK) made tick_inner 61 upvalues, past the client Lua's
    -- limit of 60, and quest/engine.lua stopped compiling in game.
    TK.gid.tried, TK.gid.refused = nil, nil
    local p = g_pending
    g_pending = nil
    if not p or not p.npc_id or not p.quest_id then
        return
    end
    local on = safe(function() return core.quests.is_on_quest(p.quest_id) end) == true
    -- A turn-in is proven by the hand-in, not by the quest being gone
    -- (2.215.0): a timed quest that expired is gone too, and Grelin
    -- Whitebeard was learned as the taker of Scalding Mornbrew that way.
    local turned = npc.was_turned_in(p.quest_id)
        or safe(function() return core.quests.is_quest_flagged_completed(p.quest_id) end) == true
    local landed = (p.kind == "accept" and on) or (p.kind == "turnin" and not on and turned)
    if landed then
        guide.learn_quest_npc(p.kind, p.quest_id, p.npc_id)
        debug("learned %s npc %d for quest %d", p.kind, p.npc_id, p.quest_id)
    end
end

-- ----------------------------------------------------------------------------
-- GOAL HANDLERS
-- ----------------------------------------------------------------------------

--- The quest this accept / turn-in goal is about right now (2.134.0).
---
--- RestedXP names it in quest_id, or in ids for a multi-quest goal
--- (acceptmultiple / turninmultiple), which used to fall through to the
--- generic talk path: the bot opened a frame, called the goal done after two
--- seconds and never handed anything in. The first id still to do wins:
--- an accept not yet in the log and never completed, a turn-in in the log and
--- not handed in this session.
---
--- Returns (quest_id) to work on, or (nil, why) when every id the goal names
--- is already satisfied - RestedXP's snapshot can lag a tick, or the player
--- did it by hand (2.63.0) - or the goal names none.
local function resolve_quest(goal, kind)
    local ids = guide.goal_quest_ids(goal)
    if #ids == 0 then
        return nil, "names no quest"
    end
    local skipped = type(state.quest.skipped) == "table" and state.quest.skipped or {}
    for i = 1, #ids do
        local id = ids[i]
        local on = safe(function() return core.quests.is_on_quest(id) end)
        local done = safe(function() return core.quests.is_quest_flagged_completed(id) end) == true
        if kind == "accept" then
            if on ~= true and not done and not skipped[id] then
                return id
            end
        elseif on == true and not npc.was_turned_in(id) then
            return id
        elseif on == nil and not done and not npc.was_turned_in(id) then
            -- The build cannot say: try it, the NPC's list decides.
            return id
        end
    end
    if kind == "accept" then
        return nil, "already accepted or completed"
    end
    return nil, "no quest of this goal is in the log (handed in, or never taken)"
end

--- Anything the quest log says about the goal's quests, as one string, so
--- a change between ticks counts as progress.
local function log_signature(goal)
    local ids = guide.goal_quest_ids(goal)
    local parts = {}
    for i = 1, #ids do
        local id = ids[i]
        local on = safe(function() return core.quests.is_on_quest(id) end) == true
        local done = safe(function() return core.quests.is_quest_flagged_completed(id) end) == true
        parts[#parts + 1] = (on and "1" or "0") .. (done and "1" or "0")
    end
    return table.concat(parts, ",")
end

local function stall_reset(now)
    g_stall.t, g_stall.seen, g_stall.best, g_stall.reach = now, now, nil, false
    g_stall.npc_seq, g_stall.log, g_stall.recoveries, g_stall.pos, g_stall.talked = nil, nil, 0, nil, nil
end

--- Record this tick's progress. `d` is the distance to what the bot is
--- walking to (the NPC, or the waypoint while no NPC is found). Returns true
--- when STALL_AFTER seconds have passed without any.
local function stalled(now, goal, d)
    -- Ticks spent fighting, resting or looting are not this goal's time.
    if (now - g_stall.seen) > 1.0 then
        g_stall.t = now
    end
    g_stall.seen = now
    local moved = false
    if type(d) == "number" then
        -- Circling a door at 5-8 yards looks like 2-yard gains. Once we are
        -- that close, only reaching the NPC (or a dialog / log change) counts.
        local was_far = g_stall.best == nil or g_stall.best > TALK_ARRIVE
        if g_stall.best == nil or d < g_stall.best - STALL_GAIN then
            if was_far or d <= TALK_REACH then
                g_stall.best = d
                moved = true
            elseif d < g_stall.best then
                g_stall.best = d
            end
        end
        local in_reach = d <= TALK_REACH
        if in_reach and not g_stall.reach then
            moved = true
        end
        g_stall.reach = in_reach
    end
    local ns = npc.progress_seq()
    if ns ~= g_stall.npc_seq then
        g_stall.npc_seq = ns
        moved = true
    end
    local sig = log_signature(goal)
    if sig ~= g_stall.log then
        g_stall.log = sig
        moved = true
    end
    if g_talk_opened ~= 0 and g_stall.talked ~= true then
        g_stall.talked = true
        moved = true
    end
    -- A recorded road can lead away from the goal for a while before it
    -- turns toward it; covering ground on one is progress.
    if travel_routes.road then
        local me = safe(function() return izi.me():get_position() end)
        if me and (g_stall.pos == nil or (geometry.distance_flat(me, g_stall.pos) or 0) >= 5) then
            g_stall.pos = { x = me.x, y = me.y, z = me.z }
            moved = true
        end
    end
    if moved then
        g_stall.t = now
        return false
    end
    return (now - g_stall.t) >= STALL_AFTER
end

--- The recovery sequence for a stalled NPC goal. Returns true when the goal
--- was given up on.
local function recover_stall(now, goal, label)
    -- A stall at a learned NPC (2.185.0): the pairing is suspect - forget it.
    if g_giver_learned and g_giver_learned.npc then
        trail("act", "%s: stalled at learned npc %d - forgotten", tostring(label), g_giver_learned.npc)
        guide.forget_quest_npc(g_giver_learned.kind, g_giver_learned.qid, g_giver_learned.npc, g_giver_learned.text)
        g_giver_learned = nil
    end
    g_stall.recoveries = g_stall.recoveries + 1
    trail("act", "%s: no progress for %.0f s - recovery %d of %d", tostring(label),
        STALL_AFTER, g_stall.recoveries, STALL_MAX)
    npc.close()
    movement.nav_stop()
    guide.invalidate()
    g_giver_walk = nil
    g_talk_opened = 0
    g_act_until = 0
    g_hold_until = 0
    g_close_in = false
    g_bind_asked = false
    g_bad_givers = {}
    g_bad_since = 0
    TK.gid.tried, TK.gid.refused = nil, nil
    g_force_path = true
    g_stall.t, g_stall.best, g_stall.reach = now, nil, false
    if g_stall.recoveries >= STALL_MAX then
        core.log_warning(string.format(
            "[Master Farmer - Grindbot] Quest goal '%s': no progress after %d recoveries - skipping it.",
            tostring(label), STALL_MAX))
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    return false
end

-- FAILED QUESTS (2.162.0). A timed quest (Scalding Mornbrew Delivery: a hot
-- drink to deliver in minutes) that runs out cannot be handed in - the NPC
-- simply does not list it, and the 12:24 session "tried another NPC" at
-- every unit near the trainer. The quest log says so (is_complete == -1):
-- the quest is abandoned, the bot walks back to where it was accepted,
-- takes it again, and the turn-in goal carries on. Where each quest was
-- accepted is remembered (npc id + position), saved with the settings.
local g_accept_at = {}       -- quest id -> { npc = id, x, y, z }
local g_redo = nil           -- { qid, title, npc, pos, since }
local REDO_TIMEOUT = 180

do
    local ok_s, settings = pcall(require, "settings")
    if ok_s and type(settings) == "table" and type(settings.register) == "function" then
        settings.register("accept_at", function()
            local parts = {}
            for qid, a in pairs(g_accept_at) do
                parts[#parts + 1] = string.format("%d:%d:%.1f:%.1f:%.1f", qid, a.npc, a.x, a.y, a.z)
            end
            return #parts > 0 and table.concat(parts, ";") or nil
        end, function(v)
            if type(v) ~= "string" then return end
            for qid, id, x, y, z in v:gmatch("(%d+):(%d+):([%-%d%.]+):([%-%d%.]+):([%-%d%.]+)") do
                g_accept_at[tonumber(qid)] = { npc = tonumber(id), x = tonumber(x), y = tonumber(y), z = tonumber(z) }
            end
        end)
    end
end

local function remember_accept(qid, npc_id, unit)
    local p = unit and safe(function() return unit:get_position() end)
    if type(qid) ~= "number" or type(npc_id) ~= "number" or not p then return end
    g_accept_at[qid] = { npc = npc_id, x = p.x, y = p.y, z = p.z }
    local ok_s, settings = pcall(require, "settings")
    if ok_s and type(settings) == "table" and type(settings.mark_dirty) == "function" then
        settings.mark_dirty()
    end
end

--- Walk back to the giver of a failed quest and take it again. True while
--- it holds the tick.
local function redo_accept(player, goal, label)
    local r = g_redo
    if not r then return false end
    local now = izi.now()
    if safe(function() return core.quests.is_on_quest(r.qid) end) == true then
        trail("act", "quest %d taken again - back to the turn-in", r.qid)
        g_redo = nil
        return false
    end
    if (now - r.since) > REDO_TIMEOUT then
        trail("act", "could not take quest %d again in %ds - skipping the turn-in", r.qid, REDO_TIMEOUT)
        g_redo = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    local unit = targeting.find_npc(player, r.npc, 40)
    local up = unit and safe(function() return unit:get_position() end)
    local d = up and geometry.distance_flat(safe(function() return player:get_position() end) or up, up)
    if not unit or (type(d) == "number" and d > TALK_ARRIVE) then
        local dest = up or r.pos
        if walk_to(dest, "take " .. tostring(r.title) .. " again", TALK_ARRIVE) then
            state.set_note("Quest", "Guide: going back to take " .. tostring(r.title) .. " again")
            return true
        end
        if not unit then
            state.set_note("Quest", "Guide: looking for the giver of " .. tostring(r.title))
            return true
        end
    end
    movement.nav_stop()
    local result = npc.accept(player, r.qid, r.title, r.npc, unit)
    if result == "done" or result == "skipped" then
        npc.close_frames()
        trail("act", "quest %d taken again - back to the turn-in", r.qid)
        g_redo = nil
        return false
    end
    if result == "not_offered" or result == "gave_up" or result == "bags_full" then
        npc.close()
        trail("act", "the giver would not offer quest %d again (%s) - skipping the turn-in", r.qid, tostring(result))
        g_redo = nil
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    state.set_note("Quest", "Guide: taking " .. tostring(r.title) .. " again")
    return true
end

local function dialog_goal(player, goal, kind, wps, label)
    local now = izi.now()
    local qid = nil
    if kind == "accept" or kind == "turnin" then
        local why
        qid, why = resolve_quest(goal, kind)
        if not qid then
            trail("act", "%s goal %d: %s - next goal", kind, goal.index or 0, tostring(why))
            if why ~= "names no quest" then
                guide.mark_goal_done(guide.step_num(), goal.index)
                return true
            end
            -- No quest id at all: an NPC to speak to is all that is known.
        end
    end
    if kind == "turnin" and qid then
        if g_redo and g_redo.qid == qid then
            if redo_accept(player, goal, label) then return true end
        elseif npc.quest_log_state(qid) == "failed" then
            local title = quest_title(goal, kind, qid)
            local a = g_accept_at[qid] or nil
            core.log_warning(string.format("[Master Farmer - Grindbot] Quest %s has FAILED (its timer ran out)%s.",
                tostring(title or qid), a and " - abandoning it and taking it again" or " - abandoning it"))
            npc.close()
            npc.abandon(qid)
            if a then
                trail("act", "quest %d failed - abandoned, back to npc %d to take it again", qid, a.npc)
                g_redo = { qid = qid, title = title or tostring(qid), npc = a.npc,
                    pos = { x = a.x, y = a.y, z = a.z }, since = now }
                return true
            end
            trail("act", "quest %d failed - abandoned; its giver is not known, skipping the turn-in", qid)
            guide.mark_goal_done(guide.step_num(), goal.index)
            return true
        end
    end
    if now < g_hold_until then
        state.set_note("Quest", "Guide: waiting - " .. tostring(label) .. " not complete at the NPC")
        return true
    end

    local unit, how = find_giver(player, goal, kind, wps, qid)
    g_giver_learned = nil
    if unit and type(how) == "string" and how:find("^learned id") then
        g_giver_learned = { kind = kind, qid = goal.quest_id, npc = tonumber(how:match("(%d+)$")), text = goal.text }
    end

    -- Distance to what the bot is working toward, for the stall check.
    -- Flat: a 3D read against an outdoor-terrain z (or an NPC on another
    -- floor) jitters by more than STALL_GAIN while the character circles.
    local me = safe(function() return player:get_position() end)
    local track_d
    local wp_t = (#wps > 0) and wps[math.min(g_move, #wps)].pos or nil
    if unit then
        local up = safe(function() return unit:get_position() end)
        track_d = me and up and geometry.distance_flat(me, up) or nil
        -- An NPC picked away from the waypoint (2.158.0): the 11:28 turn-in
        -- chose Balir by the previous step's waypoint, then walked 354 yd to
        -- the real one - away from Balir - and the stall check fired at 30 s
        -- on a walk that was going fine. Track the waypoint then.
        local off = up and wp_t and geometry.distance_flat(up, wp_t)
        if type(off) == "number" and off > TALK_SEARCH_FAR then
            track_d = me and geometry.distance_flat(me, wp_t) or track_d
        end
    elseif wp_t then
        track_d = me and geometry.distance_flat(me, wp_t) or nil
    end
    if stalled(now, goal, track_d) then
        recover_stall(now, goal, label)
        return true
    end

    if not unit and TK.gid.refused and qid then
        -- The goal's own NPC listed no such quest (2.215.0). Nothing else in
        -- reach is evidence of a better one, so the goal is set aside here and
        -- RestedXP's own state decides what comes next - the guide steps back
        -- for a failed timed quest (Scalding Mornbrew Delivery, 5 min), the
        -- set-aside goal is asked again on "step complete" (30 s).
        local r = TK.gid.refused
        trail("act", "%s %d: %s (npc %s), the guide's NPC for it at the waypoint, does not offer it - "
            .. "on quest %s, completed %s - setting the goal aside, no other NPC tried",
            kind, qid, tostring(r.name), tostring(r.npc),
            tostring(safe(function() return core.quests.is_on_quest(qid) end)),
            tostring(safe(function() return core.quests.is_quest_flagged_completed(qid) end)))
        -- TK.gid stays until the goal changes (its reset), so a tick that
        -- still lands on this goal cannot fall through to the nearest NPC.
        guide.mark_goal_done(guide.step_num(), goal.index)
        return true
    end
    if not unit and TK.gid.tried then
        -- The identified NPC timed out (gave_up): it gets the BAD_GIVER_RETRY
        -- second chance below, not a walk through every other NPC here.
        if next(g_bad_givers) ~= nil then
            if g_bad_since == 0 then
                g_bad_since = now
            elseif (now - g_bad_since) >= BAD_GIVER_RETRY then
                trail("act", "%s: asking %s again", kind, tostring(TK.gid.tried))
                g_bad_givers = {}
                g_bad_since = 0
            end
        end
        state.set_note("Quest", "Guide: waiting to ask " .. tostring(TK.gid.tried) .. " again")
        return true
    end
    if not unit then
        -- Every NPC here was ruled out. Give them another chance after a
        -- while (2.63.0): a giver that timed out once - lag, a frame that
        -- opened late - is usually fine the second time, and until now the
        -- list was only cleared when the goal changed, i.e. by the watchdog.
        if next(g_bad_givers) ~= nil then
            if g_bad_since == 0 then
                g_bad_since = now
            elseif (now - g_bad_since) >= BAD_GIVER_RETRY then
                trail("act", "%s: retrying every NPC at the waypoint", kind)
                g_bad_givers = {}
                g_bad_since = 0
            end
        end
        -- At the door of a building the 12-yard search misses the NPC inside,
        -- and walking to the outdoor-terrain z never enters. Search farther,
        -- then walk a few yards in at the player's own height.
        local at_door = false
        for i = 1, #wps do
            if near(wps[i].pos, TALK_ARRIVE) then
                at_door = true
                break
            end
        end
        if at_door then
            for i = 1, #wps do
                unit = guide.nearest_talkable(player, TALK_SEARCH_FAR, wps[i].pos, g_bad_givers, kind == "accept" or kind == "turnin")
                if unit then
                    how = "inside the building"
                    break
                end
            end
            if not unit then
                unit = guide.nearest_talkable(player, TALK_SEARCH_FAR, nil, g_bad_givers, kind == "accept" or kind == "turnin")
                if unit then
                    how = "nearest nearby"
                end
            end
        end
        if not unit then
            if at_door and me and #wps > 0 then
                local dest = wps[1].pos
                local dx = dest.x - me.x
                local dy = dest.y - me.y
                local len = math.sqrt(dx * dx + dy * dy)
                if len > 1 then
                    local step = math.min(STEP_INSIDE, len)
                    local inside = {
                        x = me.x + dx / len * step,
                        y = me.y + dy / len * step,
                        z = me.z,
                    }
                    trail("act", "%s: at the door, no giver - stepping inside", kind)
                    walk_to(inside, label, 2)
                    return true
                end
            end
            if at_door then
                trail("act", "%s: at the door, no giver within %.0f yd", kind, TALK_SEARCH_FAR)
            end
            return false
        end
    end
    g_bad_since = 0
    local d = track_d or 99
    -- An interact the NPC refused (out of range, a UI error): the next one
    -- is made from closer.
    if npc.take_refused() and not g_close_in then
        g_close_in = true
        trail("act", "%s: the NPC refused the interaction - closing in", tostring(label))
    end
    local reach = g_close_in and CLOSE_REACH or TALK_REACH
    if d > reach then
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
            walk_to(p, label, math.max(reach - 1.0, 1.5))
            return true
        end
        return false
    end
    g_giver_walk = nil
    movement.nav_stop()

    local npc_id = geometry.object_id(unit)
    local uname = safe(function() return unit:get_name() end)
    trail("act", "%s with %s npc %s via %s", kind, tostring(uname), tostring(npc_id), tostring(how))
    -- Identified, not guessed (2.215.0): see TK.gid and find_giver.
    local identified = type(how) == "string" and (how:find("^guide") or how:find("^learned id")
        or how == "raid marker" or how:find("^waypoint title")) ~= nil
    if identified and qid then
        TK.gid.tried = tostring(uname or npc_id)
    end
    if qid then
        g_pending = { kind = kind, quest_id = qid, npc_id = npc_id }
        state.quest.id = qid
        local title = quest_title(goal, kind, qid)
        local result
        if kind == "accept" then
            state.set_note("Quest", "Guide: accept " .. tostring(title or qid))
            result = npc.accept(player, qid, title, npc_id, unit)
        else
            state.set_note("Quest", "Guide: turn in " .. tostring(title or qid))
            result = npc.turn_in(player, qid, title, npc_id, unit)
        end
        if result == "done" and kind == "accept" then
            remember_accept(qid, npc_id, unit)
        end
        if result == "done" or result == "skipped" then
            -- Landed and proven by quest/npc. Close the windows once and move
            -- on: the dialog keeps answering "done" for this quest, so nothing
            -- re-interacts while RestedXP catches up. A multi-quest goal comes
            -- back here for its next id rather than being counted done.
            trail("act", "%s quest %d: %s", kind, qid, result)
            npc.close_frames()
            guide.invalidate()
            g_not_ready = 0
            g_close_in = false
            if resolve_quest(goal, kind) == nil then
                guide.mark_goal_done(guide.step_num(), goal.index)
            end
            return true
        end
        if result == "not_ready" then
            -- The NPC has the quest but will not take it yet. Re-reading the
            -- guide once more covers an objective that finished a moment ago;
            -- a second refusal means RestedXP is ahead of the server.
            g_not_ready = g_not_ready + 1
            npc.close()
            guide.invalidate()
            if g_not_ready >= NOT_READY_MAX then
                core.log_warning(string.format(
                    "[Master Farmer - Grindbot] Quest %s: RestedXP says turn it in, the NPC says it is not complete - skipping the goal.",
                    tostring(title or qid)))
                guide.mark_goal_done(guide.step_num(), goal.index)
                g_not_ready = 0
            else
                trail("act", "turn in %d: not complete at the NPC - holding %.0f s", qid, NOT_READY_HOLD)
                g_hold_until = now + NOT_READY_HOLD
            end
            return true
        end
        if result == "bags_full" then
            -- The quest was offered and Accept did not land (2.160.0): full
            -- bags. Sell first; the giver is not ruled out, and the accept
            -- is tried again once the trip is over.
            npc.close()
            g_pending = nil
            g_close_in = false
            local ok_vd, vnd = pcall(require, "vendor")
            local going = ok_vd and type(vnd) == "table" and type(vnd.request_bag_trip) == "function"
                and vnd.request_bag_trip("accept " .. tostring(title or qid) .. " failed - bags full", player)
            if going then
                trail("act", "accept %d: bags full - selling first, then back to this quest", qid)
                g_hold_until = now + 2
                return true
            end
            result = "gave_up"
        end
        if kind == "turnin" and (result == "not_offered" or result == "gave_up")
            and npc.quest_log_state(qid) == "failed" then
            -- Not the NPC's fault: the quest failed. The check at the top of
            -- dialog_goal abandons it and takes it again next tick.
            npc.close()
            g_pending = nil
            return true
        end
        if (result == "not_offered" or result == "gave_up") and type(how) == "string" and how:find("^learned id") then
            guide.forget_quest_npc(kind, qid, npc_id, goal.text)
            trail("act", "%s: learned npc %s refused quest %d - forgotten", kind, tostring(npc_id), qid)
        end
        if result == "not_offered" and identified then
            TK.gid.refused = { name = tostring(uname), npc = npc_id }
        end
        if result == "not_offered" or result == "gave_up" then
            -- Not this NPC: rule it out and let find_giver pick the next.
            local g = safe(function() return unit:get_guid() end)
            if g then
                g_bad_givers[g] = true
            end
            trail("act", "%s: %s does not have quest %d (%s) - trying another NPC", kind,
                tostring(safe(function() return unit:get_name() end)), qid, result)
            npc.close()
            g_pending = nil
            g_close_in = false
        end
        debug("%s quest %d at %s (npc %s)", kind, qid, tostring(how), tostring(npc_id))
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
    local gossip_open = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    -- ".home" (2.134.0): the innkeeper's bind option, picked by its icon from
    -- this frame's own options. The confirmation popup is answered by
    -- events.lua (CONFIRM_BINDER).
    if gossip_open and not g_bind_asked and string.lower(goal.action or "") == "home" then
        local bind = gossip.find({ icon = "BINDER", type = "binder" })
        if bind then
            g_bind_asked = true
            pcall(bind)
            g_talk_opened = now
            trail("act", "asked %s to bind the hearthstone", tostring(safe(function() return unit:get_name() end)))
            state.set_note("Quest", "Guide: binding the hearthstone")
            return true
        end
    end
    local ok_v, vendor = pcall(require, "vendor")
    local merchant = ok_v and type(vendor) == "table" and type(vendor.merchant_open) == "function"
        and vendor.merchant_open() == true

    -- VENDOR STEPS NEED THE MERCHANT WINDOW (2.204.0). RestedXP ticks a
    -- ".vendor" step off on MERCHANT_SHOW. The bot talked to the nearest NPC
    -- at the waypoint (npc 1694, a quest giver), counted the open GOSSIP as
    -- done, and the step retried every 30 s for two hours (17:46-19:53 log).
    -- Now: an NPC the game does not flag as a vendor (0x80) is skipped; a
    -- gossip gets its vendor option selected; an NPC that will not open a
    -- merchant after TK.VEND_TRIES tries is ruled out and the next one is tried.
    if string.lower(goal.action or "") == "vendor" and not merchant then
        local g = safe(function() return unit:get_guid() end)
        if g ~= TK.vend.guid then TK.vend = { guid = g, tries = 0, next_t = 0 } end
        local flags = safe(function() return unit:get_npc_flags() end)
        local not_vendor = type(flags) == "number" and flags > 0 and math.floor(flags / TK.NPC_VENDOR) % 2 == 0
        if not_vendor or TK.vend.tries >= TK.VEND_TRIES then
            if g then g_bad_givers[g] = true end
            trail("act", "vendor step: npc %s %s - trying another NPC", tostring(npc_id_of_unit(unit)),
                not_vendor and "is not a vendor" or "opened no merchant window")
            pcall(function() core.quests.close_gossip() end)
            g_talk_opened = 0
            TK.vend = { guid = nil, tries = 0, next_t = 0 }
            return true
        end
        if gossip_open then
            if now >= TK.vend.next_t then
                TK.vend.next_t = now + 1.5
                TK.vend.tries = TK.vend.tries + 1
                local picked = gossip.select({ icon = "VENDOR", icon_num = 1, type = "vendor",
                    words = { "browse your goods", "let me browse", "your wares", "buy from you", "buy something" } })
                trail("act", "vendor step: gossip - %s (try %d)", picked and "vendor option selected"
                    or "no vendor option", TK.vend.tries)
                if not picked then TK.vend.tries = TK.VEND_TRIES end
            end
            state.set_note("Quest", "Guide: opening the merchant - " .. label)
            return true
        end
    end
    -- GUIDE GOSSIP CHOICE (2.206.0). RestedXP picks a step's gossip option
    -- itself (.gossipoption / .skipgossipid by gossip option id, .skipgossip
    -- by npc id + option number) when its gossip automation is on. When the
    -- frame is still open TK.GOSSIP_AFTER later, the bot makes the same
    -- choice from the guide files (data/rxp_targets M.steps), once per frame.
    if gossip_open and kind == "talk" and type(guide.rxp_step_for) == "function" then
        if g_talk_opened == 0 then g_talk_opened = now end
        local st = guide.rxp_step_for(wps)
        local key = tostring(safe(function() return unit:get_guid() end)) .. ":" .. tostring(g_talk_opened)
        if st and (st.g or st.s) and TK.gsel.key ~= key and (now - g_talk_opened) >= TK.GOSSIP_AFTER then
            TK.gsel.key = key
            local rows = safe(function() return core.quests.get_gossip_options() end)
            local picked = nil
            if type(rows) == "table" and st.g then
                for i = 1, #rows do
                    local id = type(rows[i]) == "table" and rows[i].gossip_option_id or nil
                    for k = 1, #st.g do
                        if id == st.g[k] then picked = id break end
                    end
                    if picked then break end
                end
            end
            if not picked and type(rows) == "table" and st.s then
                local quests_n = #(safe(function() return core.quests.get_gossip_available_quests() end) or {})
                    + #(safe(function() return core.quests.get_gossip_active_quests() end) or {})
                local want = nil
                if #st.s == 0 then
                    want = 1
                elseif st.s[1] == npc_id_of_unit(unit) then
                    want = st.s[2] or 1
                elseif #st.s == 1 and st.s[1] <= 9 then
                    want = st.s[1]
                end
                local row = want and rows[want] or nil
                if quests_n == 0 and type(row) == "table" then
                    picked = (type(row.gossip_option_id) == "number" and row.gossip_option_id ~= 0)
                        and row.gossip_option_id or want
                end
            end
            if picked then
                trail("act", "guide gossip choice: option %s", tostring(picked))
                pcall(function() core.quests.select_gossip_option(picked) end)
                g_talk_opened = now
                return true
            end
        end
    end
    local trainer_n = safe(function() return core.quests.get_num_trainer_services() end)
    local trainer = type(trainer_n) == "number" and trainer_n > 0
    -- A flight master's map counts as its frame (2.95.0): talking to it is
    -- what learns the flight path (".fp"), and the map is what opens.
    local taxi_n = safe(function() return core.taxi.num_nodes() end)
    local taxi = type(taxi_n) == "number" and taxi_n > 0
    if gossip_open or merchant or trainer or taxi then
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
            -- RestedXP completes a ".vendor" step on MERCHANT_CLOSED after a
            -- MERCHANT_SHOW (RXPGuides functions.lua, addon.functions.vendor),
            -- ".trainer" on TRAINER_CLOSED: the window has to be CLOSED, not
            -- just opened (2.205.0). close_gossip left the merchant up.
            if merchant then pcall(function() core.input.close_merchant() end) end
            if trainer then pcall(function() core.quests.close_trainer() end) end
            g_talk_opened = 0
            return true
        end
        state.set_note("Quest", "Guide: at " .. label)
        return true
    end
    if now >= g_act_until then
        -- The last interact drew a UI error instead of a window: the next is
        -- made from closer, not repeated from the same spot.
        if g_talk_interact_t > 0 and not g_close_in and events
            and type(events.since) == "function" and events.since("UI_ERROR_MESSAGE", g_talk_interact_t) then
            g_close_in = true
            trail("act", "%s: the NPC refused the interaction - closing in", tostring(label))
            return true
        end
        g_act_until = now + ACT_GAP
        g_talk_interact_t = now
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


--- Select the taxi option of the open gossip frame. True when one was chosen.
-- 2.239.0 flight-master helpers, in one table (this file is at Lua's 200-local limit).
local FM = {
    GOSSIP_TRIES = 3,          -- gossip windows without a flight option before the next NPC
    FLAG = 0x2000,             -- UNIT_NPC_FLAG_FLIGHTMASTER
}

--- GUIDs as text (2.239.0): on this client get_guid() can be userdata, and
--- two reads of the same GUID need not compare equal.
function FM.guid_text(u)
    local g = safe(function() return u:get_guid() end)
    if g == nil then return nil end
    local ok, s = pcall(tostring, g)
    if ok and type(s) == "string" and s ~= "" then return s end
    return nil
end

function FM.is_flight_master(u)
    local f = safe(function() return u:get_npc_flags() end)
    return type(f) == "number" and f > 0 and math.floor(f / FM.FLAG) % 2 == 1
end

--- One log line with what an open gossip window offers (why no flight option).
function FM.log_gossip_options(who)
    local parts = {}
    local opts = safe(function() return core.quests.get_gossip_options() end)
    if type(opts) == "table" then
        for i = 1, math.min(#opts, 8) do
            local o = opts[i]
            if type(o) == "table" then
                parts[#parts + 1] = string.format("'%s' type=%s icon=%s", tostring(o.name),
                    tostring(o.gossip_type), tostring(o.icon))
            end
        end
    end
    trail("travel", "%s's gossip has no flight option: %s", tostring(who),
        #parts > 0 and table.concat(parts, "; ") or "no options listed")
end

local function taxi_gossip()
    -- gossip.lua (2.144.0): izi's TAXI icon, then type "taxi" / wording.
    return (gossip.select({ icon = "TAXI", type = "taxi", words = { "fly", "flight" } }))
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
    local gossip_open = safe(function() return core.quests.is_gossip_frame_shown() end) == true
    if gossip_open then
        if now >= g_act_until then
            g_act_until = now + ACT_GAP
            if taxi_gossip() then
                trail("act", "flight master: taxi option selected")
            else
                g_fly_noopt = g_fly_noopt + 1
                if g_fly_noopt == 1 then FM.log_gossip_options("the flight master") end
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
local g_map_logged = false

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
    -- Not on this game version (WoW Forever: no Outland, no TBC-added
    -- flight points, 2.124.0).
    local cat = catalog()
    if cat and type(cat.in_game) == "function" and not cat.in_game(n) then return false end
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
        -- 2.239.0: only a node this character can fly to now (not CURRENT,
        -- DISTANT or undiscovered). "" = the client does not say: allowed.
        local ntype = safe(function() return core.taxi.node_type(i) end)
        if type(ntype) == "string" and ntype ~= "" and ntype ~= "REACHABLE" then list = nil end
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
    local fkey = faction_key(player)
    if not cat then return false end
    -- CONTINENT (2.117.0). The catalog uses continent ids (0 Eastern Kingdoms,
    -- 1 Kalimdor, 530 Outland). core.get_map_id() is only documented as "the
    -- current map"; the 02:18 log refused a 3795 yd trip from Lakeshire with
    -- "no flight point shortens it", which is what a non-continent id gives.
    -- Anything else is replaced by the continent of the nearest flight point.
    local map, raw_map = gamever.continent_of(here)
    if type(map) ~= "number" then return false end
    if not g_map_logged then
        g_map_logged = true
        trail("travel", "core.get_map_id() = %s -> continent %s", tostring(raw_map), tostring(map))
    end

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
            return trip_fail(key, string.format(
                "no flight point shortens the %.0f yd trip (continent %s, %s, nearest %s %.0f yd, best landing %.0f yd from goal)",
                dist, tostring(map), tostring(fkey), start and start.name or "none", sd or -1, near_goal or -1))
        end
        g_trip = { key = key, start = start, target = { x = target.x, y = target.y, z = target.z },
            tried = {}, fm_guid = nil, fm_tries = 0, fm_name = nil, gossip_misses = 0 }
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
            if taxi_gossip() then
                trip.gossip_misses = 0
            else
                -- 2.239.0: the options can arrive after the frame; give the
                -- window FM_GOSSIP_TRIES looks, and log what it offered.
                trip.gossip_misses = (trip.gossip_misses or 0) + 1
                if trip.gossip_misses == 1 then FM.log_gossip_options(trip.fm_name or "the NPC") end
                if trip.gossip_misses >= FM.GOSSIP_TRIES then
                    if trip.fm_guid then trip.tried[trip.fm_guid] = true end
                    trip.fm_guid, trip.fm_tries, trip.gossip_misses = nil, 0, 0
                    pcall(function() core.quests.close_gossip() end)
                end
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
                and FM.guid_text(u) == trip.fm_guid then
                unit = u
                break
            end
        end
        if not unit then trip.fm_guid = nil end
    end
    if not unit then
        -- 2.239.0: the NPC flagged FLIGHTMASTER first (guards and vendors
        -- stand at flight points too), then the nearest friendly NPC.
        local best_d, best_fm = nil, false
        local list = targeting.visible_objects() or {}
        for i = 1, #list do
            local u = list[i]
            if u and safe(function() return u:is_valid() end) == true
                and safe(function() return u:is_player() end) ~= true
                and safe(function() return u:is_dead() end) ~= true
                and safe(function() return player:can_attack(u) end) ~= true then
                local g = FM.guid_text(u)
                local p = safe(function() return u:get_position() end)
                if g ~= nil and not trip.tried[g] and p and d2(p, sp) <= FM_SEARCH then
                    local d = d2(here, p)
                    local fm = FM.is_flight_master(u)
                    if best_d == nil or (fm and not best_fm) or (fm == best_fm and d < best_d) then
                        unit, best_d, best_fm = u, d, fm
                    end
                end
            end
        end
        if not unit then
            return trip_fail(key, "no flight master found at " .. sp.name)
        end
        trip.fm_guid = FM.guid_text(unit)
        trip.fm_name = safe(function() return unit:get_name() end)
        trip.fm_tries, trip.gossip_misses = 0, 0
        trail("travel", "flight master candidate %s%s", tostring(trip.fm_name),
            best_fm and " (flight master flag)" or "")
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

-- CLOSEST OF THE QUEST'S MOB (2.139.0). The raid-marked unit used to win
-- outright however far away it was: every log of 2026-09-29 engaged a marked
-- Ragged Young Wolf 43-67 yd off ("no progress toward the combat", "target
-- unreachable") with others of the same wolf much closer. The mark, a name
-- match or a drop-source match now only says WHICH mob the step wants (its
-- npc id); the closest fightable unit with that id is the one attacked, and
-- the id is kept for the rest of the goal. The camp fallback (a guess) never
-- sets it.
local g_goal_npc = {}            -- "step|goal" -> npc id the goal is killing

local function npc_id_of(unit)
    local id = unit and safe(function() return unit:get_npc_id() end) or nil
    if type(id) == "number" and id > 0 then return id end
    return nil
end

local g_rxp_targets_logged = nil

local function kill_goal(player, goal, kind, wps, label)
    local now = izi.now()
    if now < g_scan_until then
        return false
    end
    g_scan_until = now + SCAN_GAP
    -- RestedXP's target lines for this step (2.199.0): logged once per change.
    if type(guide.step_target_names) == "function" then
        local names = guide.step_target_names()
        -- 2.200.0: plus the guide files' target mobs for this goal's quest.
        if #names == 0 and type(guide.rxp_quest_mobs) == "function" then
            names = guide.rxp_quest_mobs(goal.quest_id)
        end
        local line = tostring(guide.step_num()) .. ":" .. table.concat(names, ", ")
        if line ~= g_rxp_targets_logged then
            g_rxp_targets_logged = line
            trail("quest", "step %s RestedXP targets: %s", tostring(guide.step_num()),
                #names > 0 and table.concat(names, ", ") or "none")
        end
    end
    local gkey = tostring(guide.step_num()) .. "|" .. tostring(goal.index)
    local want_id = g_goal_npc[gkey]
    -- A mob RestedXP has marked with a raid icon names the target (2.53.0).
    local marked = guide.find_marked(player, MOB_RANGE, "hostile")
    -- Not one combat movement has given up on (2.76.0).
    if marked and type(state.is_unreachable) == "function"
        and state.is_unreachable(safe(function() return marked:get_guid() end)) then
        marked = nil
    end
    if not want_id and marked then
        want_id = npc_id_of(marked)
    end
    local unit = nil
    if want_id then
        local d, n
        unit, d, n = guide.find_npc_mob(player, MOB_RANGE, want_id)
        if unit then
            g_goal_npc[gkey] = want_id
            trail("act", "closest %s (npc %d) at %.0f yd, %d in range",
                tostring(safe(function() return unit:get_name() end)), want_id, d or -1, n or 1)
        end
    end
    if not unit and marked then
        unit = marked
        trail("act", "raid-marked target %s", tostring(safe(function() return unit:get_name() end)))
    end
    if not unit then
        unit = guide.find_mob(player, MOB_RANGE, goal)
        if unit and npc_id_of(unit) then g_goal_npc[gkey] = npc_id_of(unit) end
    end
    if not unit and kind == "collect" then
        -- RestedXP names the item, not what drops it. First choice: a mob
        -- whose name shares a word with the item ("Tough Wolf Meat" ->
        -- "Ragged Young Wolf").
        unit = guide.find_source_mob(player, MOB_RANGE, goal)
        if unit then
            g_nosource_since = 0
            if npc_id_of(unit) then g_goal_npc[gkey] = npc_id_of(unit) end
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

-- RestedXP ".xp" / "Grind to N xp": pull the nearest valid enemy within
-- ENEMY_SCAN yards of the player, then walk the grind waypoints when none
-- are in range. Sitting "waiting at" never gained the XP (01:11 log).
local function xp_goal(player, goal, wps, label)
    local now = izi.now()
    if now < g_scan_until then
        return false
    end
    g_scan_until = now + SCAN_GAP
    local range = targeting.ENEMY_SCAN or 100
    local unit, d = nearest_xp_enemy(player, range)
    if not unit then
        return false
    end
    trail("act", "xp grind: %s at %.0f yd (within %.0f yd of the player)",
        tostring(safe(function() return unit:get_name() end)), d or -1, range)
    engage(player, unit, "Guide: " .. (label or "grinding"))
    return true
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

-- CONTINUOUS ROUTE WALKING (2.241.0). Replaces the end of tick_inner, which
-- walked one waypoint at a time and stood still at a single-waypoint goal.
--   * kill / collect / xp goals walk guide.route: every step waypoint, the
--     arrow, and a patrol ring around a lone point - looped, never "waiting at";
--   * the next point is handed to the path CHAIN_WP yards before the current
--     one is reached (a seamless retarget), moving or not, so the walk never
--     stops on a point;
--   * back from a fight, loot or rest (the route was not walked for
--     IS.rt.GAP s) the walk resumes at the NEAREST route point, not the stale
--     one it was heading for before the fight;
--   * a point the path reports unreachable / off the mesh is skipped for the
--     next one instead of standing on "cannot reach".
-- Accept / turn-in / talk / fly goals keep their own waypoints and arrival.
-- Kept on IS, outside tick_inner: tick_inner sits at the 60-upvalue limit.
IS.rt = { t = 0, GAP = 1.0 }

IS.next_wp = function(n)
    g_move = g_move + 1
    if g_move > n then
        g_move = 1
    end
end

IS.walk_route = function(player, goal, kind, wps, label)
    if #wps == 0 then
        if guide.wrong_continent() then
            state.set_note("Quest", "Guide: target is on another continent")
        else
            state.set_note("Quest", "Guide: no usable waypoint for " .. label)
        end
        return
    end
    local must_do = kind == "accept" or kind == "turnin" or kind == "talk" or kind == "fly"
    local pts = wps
    if not must_do and type(guide.route) == "function" then
        pts = guide.route(goal, kind, wps) or wps
    end
    if g_move > #pts then
        g_move = 1
    end
    local now = izi.now()
    -- Back on the route after a fight / loot / rest: the nearest point.
    if not must_do and #pts > 1 and now - IS.rt.t > IS.rt.GAP then
        local me = safe(function() return izi.me():get_position() end)
        if me then
            local best, best_d = g_move, nil
            for i = 1, #pts do
                local d = geometry.distance_flat(me, pts[i].pos)
                if type(d) == "number" and (not best_d or d < best_d) then best, best_d = i, d end
            end
            if best ~= g_move then
                trail("route", "resume at point %d of %d (%.0f yd) for %s", best, #pts, best_d or -1, tostring(label))
            end
            g_move = best
        end
    end
    IS.rt.t = now
    -- REACHABILITY FIRST (2.59.0): Sentinel's validate_destination, cached.
    -- A waypoint it reports unreachable is skipped for the next one; when
    -- every waypoint of the goal is unreachable the goal is skipped with a log
    -- line, instead of walking into the 5-minute stuck watchdog.
    -- Never for an accept / turn-in / talk goal (2.71.0): the guide cannot
    -- move on without it, so skipping it left the bot idle on "step complete"
    -- with the quest never taken. Those keep walking to their waypoint.
    if type(movement.reachable) == "function" and not must_do then
        local tried = 0
        while tried < #pts and movement.reachable(pts[g_move].pos) == false do
            IS.next_wp(#pts)
            tried = tried + 1
        end
        if tried >= #pts then
            trail("quest", "every waypoint of goal %d is unreachable - skipping it", goal.index or 0)
            core.log_warning("[Master Farmer - Grindbot] Quest goal '" .. tostring(label)
                .. "': Sentinel reports every waypoint unreachable - skipping it.")
            guide.mark_goal_done(guide.step_num(), goal.index)
            return
        end
    end
    -- DEATH ZONES (2.247.0): route points inside an area the player died in 3
    -- times are skipped; with every point inside, the goal waits outside.
    if not must_do then
        local ok_dz, dz = pcall(require, "deathzones")
        if ok_dz and type(dz) == "table" and type(dz.zone_at_pos) == "function" then
            local tried = 0
            while tried < #pts and dz.zone_at_pos(pts[g_move].pos) do
                IS.next_wp(#pts)
                tried = tried + 1
            end
            if tried >= #pts then
                local zn = dz.zone_at_pos(pts[g_move].pos)
                state.set_note("Quest", string.format("Guide: avoiding the %s area (died there %d times)",
                    tostring(zn and zn.name or "?"), zn and zn.deaths or 3))
                return
            end
        end
    end
    if #pts > 1 and not must_do then
        -- A route point the path could not reach: the next one, not a stand.
        if movement.is_blocked(pts[g_move].pos) or movement.last_fail_offmesh() then
            movement.clear_fail()
            trail("route", "point %d of %d unreachable - next point", g_move, #pts)
            IS.next_wp(#pts)
        end
        -- Chain ahead: the next point before this one is reached.
        if near(pts[g_move].pos, CHAIN_WP) then
            IS.next_wp(#pts)
        end
    elseif #pts > 1 and movement.is_moving() and near(pts[g_move].pos, CHAIN_WP) then
        IS.next_wp(#pts)
    end
    local arrive = must_do and TALK_ARRIVE or ARRIVE
    if walk_to(pts[g_move].pos, label, arrive) then
        return
    end
    -- Standing on this waypoint with nothing to do. A kill, collect or xp
    -- loop moves on to the next of its waypoints; anything else waits here
    -- for the addon to tick the goal off.
    if #pts > 1 then
        IS.next_wp(#pts)
        walk_to(pts[g_move].pos, label, arrive)
        return
    end
    if kind == "xp" then
        state.set_note("Quest", "Guide: grinding - scanning for enemies")
        return
    end
    state.set_note("Quest", "Guide: waiting at " .. label)
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
    if type(movement.keep_path) == "function" then
        movement.keep_path(false)
    end
    -- FIGHT FIRST (2.38.0). Anything attacking the player, and the fight
    -- already under way, come before every other branch of this tick. The
    -- early returns below (RestedXP not loaded, no active step, step
    -- complete, resting) used to come first, and the first two also released
    -- combat movement every tick - a mob could hit the bot with no answer.
    -- Loot a finished kill before fight_back's "combat not over" sit and
    -- before the next pull. The 00:52 log queued every corpse, then the
    -- next wolf was engaged and each corpse timed out with 0 attempts.
    do
        local u = state.target.unit
        local live = u and state.target.kind == "kill"
            and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_dead() end) ~= true
        local attacked = type(targeting.attackers) == "function" and targeting.attackers(player) > 0
        if not live and not attacked and loot and type(loot.has_work) == "function" and loot.has_work(player) then
            if not g_loot_wait then
                g_loot_wait = true
                movement.nav_stop()
                if type(movement.combat_release) == "function" then
                    movement.combat_release()
                end
            end
            state.set_note("Quest", "Guide: looting before the next pull")
            return
        end
    end
    probe("q:fight_back")
    if fight_back(player, g_label) then
        if type(targeting.attackers) == "function" and targeting.attackers(player) > 0 then
            g_loot_wait = false
        end
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
        -- STEP COMPLETE ONLY ON OUR SIDE (2.150.0). Goals the bot marked done
        -- itself (a trainer not found, a talk that timed out) do not move
        -- RestedXP on; standing here waited for ever. After STEP_RETRY the
        -- marks are forgotten and the goals are tried again.
        local now_c = izi.now()
        if guide.has_local_done() then
            if g_complete_since == 0 then g_complete_since = now_c end
            if (now_c - g_complete_since) >= STEP_RETRY then
                g_complete_since = 0
                trail("quest", "step %d: RestedXP did not move on in %ds - retrying its goals",
                    guide.step_num(), STEP_RETRY)
                guide.forget_local_done()
                return
            end
        else
            g_complete_since = 0
        end
        state.set_note("Quest", "Guide: step complete")
        return
    end
    g_complete_since = 0

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

    local key = string.format("%d|%d|%s|%s|%s", guide.step_num(), goal.index or 0,
        tostring(goal.quest_id), kind, tostring(goal.action))
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
        g_giver_walk = nil
        g_close_in = false
        g_not_ready = 0
        g_hold_until = 0
        g_bind_asked = false
        g_talk_interact_t = 0
        g_force_path = false
        stall_reset(izi.now())
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
    g_cur_kind = kind

    -- A far goal: fly most of the way (2.115.0).
    if far_travel(player, goal, kind, wps, label) then
        return
    end

    -- QUEST TRAINER STEPS (2.149.0): questing follows the step. A RestedXP
    -- ".train" / ".trainer" goal asks trainer.lua for a visit now (the
    -- every-3-levels rule is only for visits the bot decides on itself),
    -- walks to the step's waypoint until the class trainer is in sight, and
    -- is done when the visit finishes - or when RestedXP ticks it off first.
    if IS.goal(player, goal, label) then
        return
    end
    if prof_goal(player, goal, wps, label) then
        return
    end
    if train_goal(player, goal, wps, label) then
        return
    end
    if buy_goal(player, goal, wps, label) then
        return
    end

    -- BELOW LEVEL 2 (2.150.0): a ".vendor" step is still followed - RestedXP
    -- ticks it off when the merchant window opens, and skipping it on our
    -- side left the guide on that step for good ("step complete", standing
    -- at the vendor). vendor.tick sells and buys nothing below level 2.

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
    elseif kind == "xp" then
        if xp_goal(player, goal, wps, label) then
            return
        end
    end

    -- Nothing to act on here yet: walk the goal's route (2.241.0).
    IS.walk_route(player, goal, kind, wps, label)
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
--- The kind of the goal being worked ("accept", "turnin", "talk", ...), or
--- nil. trainer.lua asks, so a class trainer's quest dialog is not
--- replaced by its training window (2.125.0).
function quest.current_kind()
    return g_cur_kind
end

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
