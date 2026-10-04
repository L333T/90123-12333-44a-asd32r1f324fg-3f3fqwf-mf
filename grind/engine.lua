-- ============================================================================
-- Master Farmer - Grindbot
-- Patrol / kill / loot machine
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.230.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gui = require("gui")
local state = require("state")
local path_format = require("path_format")
local geometry = require("geometry")
local targeting = require("targeting")
local movement = require("movement")
local rotation = require("rotation")
local healing = require("healing")
local grind_zones = require("grind/zone_lookup")

local grind = {}

-- Flight-recorder probe (2.68.0). Free unless the Crash Recorder box is ticked:
-- then each one is a disk line, and the last line before a crash names the
-- native call the game died in.
local probe_el = nil
local function xprobe(tag)
    if probe_el == nil then
        local ok, m = pcall(require, "errorlog")
        probe_el = (ok and type(m) == "table" and type(m.probe) == "function") and m or false
    end
    if probe_el then
        pcall(probe_el.probe, tag)
    end
end


local hunt = nil
local profile = nil
local SCAN_GAP = 0.8
local AREA_YARDS = 80.0
local OFF_PATH = 8.0

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function row_xyz(row)
    if type(row) ~= "table" then
        return nil
    end
    local x, y, z = row.x, row.y, row.z
    if type(x) ~= "number" then
        x, y, z = row[1], row[2], row[3]
    end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return x, y, z
end

local function dist_here(here, row)
    if not here then
        return nil
    end
    local x, y, z = row_xyz(row)
    if not x then
        return nil
    end
    -- vec3:dist_to, not sqrt of the squares by hand.
    return geometry.distance(here, { x = x, y = y, z = z })
end

function grind.set_hunt(spec)
    hunt = spec
end

function grind.clear_hunt()
    hunt = nil
end

-- LAPS AND THE PROFILE'S MERCHANT (2.151.0). vendor.lua read both from
-- path_runner, which nothing starts - grind profiles run here - so "Vendor
-- each lap" never fired and a profile's own merchant was never used.
local lap_pending = 0

function grind.set_profile(path)
    profile = path
    hunt = nil
    state.grind.finished = false
    lap_pending = 0
end

--- The grind profile being walked, or nil.
function grind.current_profile()
    return profile
end

--- True once per completed lap of the profile; the caller consumes it.
function grind.take_lap()
    if lap_pending <= 0 then return false end
    lap_pending = lap_pending - 1
    return true
end

function grind.clear_profile()
    profile = nil
    hunt = nil
    state.grind.finished = false
end

--- Turn a loaded grind path into the zone shape the engine walks.
---
--- `mobs` is deliberately allowed to be nil. The zone tables name specific npc
--- ids because they describe a camp; a PathTool route describes a LOOP through
--- an area and should engage whatever is on it. targeting.id_wanted treats a
--- nil or empty list as "any npc", and the level band, tap rules and
--- reachability checks still apply - so a route with no mob list is not
--- unfiltered, it is just not restricted to a hand-listed set.
local function path_to_zone(path)
    -- coords is the path's own flat x,y,z array. Handing the same table over
    -- every tick matters: movement.plan_grind_route caches its route plan on
    -- the identity of what it is given.
    if type(path) ~= "table" or path_format.count(path) < 1 then
        return nil
    end
    return {
        coords = path.coords,
        flat = true,
        path = path,
        mobs = path.mobs,
        pull = path.pull or 50,
        merchant = path.merchant,
        map_id = path.map_id,
        name = path.name,
    }
end

local function current_zone(player)
    if hunt then
        return hunt
    end
    if profile then
        local zone = path_to_zone(profile)
        if zone then
            return zone
        end
    end
    if not player then
        return nil
    end
    local race_id = safe(function() return player:get_race_id() end)
    local level = safe(function() return player:get_level() end) or 1
    return grind_zones.lookup(race_id, level)
end

--- How many nodes this zone has, flat array or list of rows.
local function node_count(zone)
    if not zone or type(zone.coords) ~= "table" then
        return 0
    end
    if zone.flat then
        return math.floor(#zone.coords / 3)
    end
    return #zone.coords
end

--- The i-th node as something the movement layer accepts, plus the count.
--- A flat zone builds the object here, on demand, for the one node being
--- navigated to - not one per node held.
local function node_row(zone, index)
    local n = node_count(zone)
    if n < 1 then
        return nil
    end
    if index > n then
        index = 1
        state.grind.move = 1
    end
    if zone.flat then
        local k = (index - 1) * 3
        local c = zone.coords
        local x, y, z = c[k + 1], c[k + 2], c[k + 3]
        if type(x) ~= "number" then
            return nil
        end
        return { x = x, y = y, z = z }, n
    end
    return zone.coords[index], n
end

--- Every living enemy in this fight, so a corpse is still "ours" after the
--- target switches. The current kill, anything on the player or the pet, and
--- anything hitting that kill.
local function remember_fight(player)
    if type(state.note_engaged) ~= "function" then
        return
    end
    if state.target and state.target.kind == "kill" and state.target.guid then
        state.note_engaged(state.target.guid)
    end
    local me = safe(function() return player:get_guid() end)
    local pet = safe(function() return player:get_pet() end)
    local pet_guid = nil
    if pet and safe(function() return pet:is_valid() end) == true then
        pet_guid = safe(function() return pet:get_guid() end)
    end
    local cur = (state.target and state.target.kind == "kill") and state.target.guid or nil
    local attack = nil
    if type(targeting.scan_enemies) == "function" then
        attack = targeting.scan_enemies(player)
    end
    if type(attack) ~= "table" then
        return
    end
    for i = 1, #attack do
        local u = attack[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_dead() end) ~= true
            and safe(function() return u:is_in_combat() end) == true then
            local tar = safe(function() return u:get_target() end)
            local tg = tar and safe(function() return tar:is_valid() end) == true
                and safe(function() return tar:get_guid() end) or nil
            local ours = (me ~= nil and tg == me)
                or (pet_guid ~= nil and tg == pet_guid)
                or (cur ~= nil and tg == cur)
            if ours then
                local g = safe(function() return u:get_guid() end)
                if g then
                    state.note_engaged(g)
                end
            end
        end
    end
end

--- Put every dead enemy from this fight on the loot queue. Returns true
--- when a corpse is still waiting, so the next pull does not start.
local function queue_our_corpses(player)
    if gui and type(gui.is_on) == "function" and gui.is_on("loot") ~= true then
        return false
    end
    local ok_l, lt = pcall(require, "loot")
    if not ok_l or type(lt) ~= "table" or type(lt.note_kill) ~= "function" then
        return false
    end
    local list = targeting.find_corpses(player, targeting.ENEMY_SCAN or 100)
    if type(list) == "table" and type(state.was_engaged) == "function" then
        for i = 1, #list do
            local c = list[i]
            local guid = c and safe(function() return c:get_guid() end)
            if guid and state.was_engaged(guid) then
                lt.note_kill(c)
            end
        end
    end
    return type(lt.has_work) == "function" and lt.has_work(player) == true
end

local function snap_grind_node(zone, n, here)
    if not zone or not here or type(n) ~= "number" or n < 1 then
        return
    end
    local best_i = state.grind.move
    local best_d = 1e9
    for i = 1, n do
        local d = dist_here(here, (node_row(zone, i)))
        if type(d) == "number" and d < best_d then
            best_d = d
            best_i = i
        end
    end
    if type(best_d) ~= "number" or best_d > AREA_YARDS then
        return
    end
    local cur_d = dist_here(here, (node_row(zone, state.grind.move)))
    if type(cur_d) ~= "number" or cur_d > OFF_PATH or best_d + 4.0 < cur_d then
        if best_i ~= state.grind.move then
            state.grind.move = best_i
        end
    end
end

-- ============================================================================
-- STAY ON THE GRIND PATH (2.230.0)
-- ============================================================================
-- The patrol used to pull the nearest mob within 100 yd and wander off the
-- route after it. Now:
--   * a mob is pulled only once it is within the class's attack distance
--     (rotation.combat_range - the Shooting / Ranged attack distance, or the
--     melee distance; never under PULL_MIN), so the character keeps walking
--     the path until something is in reach;
--   * after a fight (and whenever it has drifted DRIFT_MAX off the line),
--     with nothing attacking, it walks back to the nearest point of the path
--     - PATH_KEEP yards counts as on it - and resumes from the node after it.
local PATH_KEEP = 5.0
local DRIFT_MAX = 8.0     -- PATH_KEEP plus slack for the Sentinel line between nodes
local PULL_MIN = 8.0
local gp = { prev_step = 1, rejoin = true, rx = nil, ry = nil }

--- x, y, z of node i, without node_row's wrap-around side effect.
local function node_xyz(zone, i)
    if zone.flat then
        local k = (i - 1) * 3
        local c = zone.coords
        local x, y, z = c[k + 1], c[k + 2], c[k + 3]
        if type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
        return nil
    end
    return row_xyz(zone.coords[i])
end

--- The nearest point of the recorded path to (hx, hy): x, y, z, distance,
--- and the index of the node the segment leads to.
local function path_nearest(zone, hx, hy)
    local n = node_count(zone)
    if n < 1 then return nil end
    local loop = not (zone.path and zone.path.loop == false)
    local bx, by, bz, bd, bnext = nil, nil, nil, nil, nil
    local last = loop and n or (n - 1)
    if n == 1 then last = 1 end
    for i = 1, last do
        local j = (i % n) + 1
        local ax, ay, az = node_xyz(zone, i)
        local cx, cy, cz = node_xyz(zone, j)
        if ax and cx then
            local vx, vy = cx - ax, cy - ay
            local len2 = vx * vx + vy * vy
            local k = 0
            if len2 > 0.0001 then
                k = ((hx - ax) * vx + (hy - ay) * vy) / len2
                if k < 0 then k = 0 elseif k > 1 then k = 1 end
            end
            local px, py, pz = ax + vx * k, ay + vy * k, az + (cz - az) * k
            local dx, dy = hx - px, hy - py
            local d = math.sqrt(dx * dx + dy * dy)
            if not bd or d < bd then
                bx, by, bz, bd, bnext = px, py, pz, d, (k >= 1) and ((j % n) + 1) or j
            end
        end
    end
    return bx, by, bz, bd, bnext
end

--- The class's attack distance, which a mob must be inside to be pulled.
local function pull_yards(player)
    local yards = 30
    if type(rotation.combat_range) == "function" then
        local ok, y = pcall(rotation.combat_range, player)
        if ok and type(y) == "number" and y > 0 then yards = y end
    end
    if yards < PULL_MIN then yards = PULL_MIN end
    return yards
end

--- Walk back onto the path when asked to (after a fight) or drifted far.
--- True while walking back (the caller does nothing else this tick).
local function rejoin_path(zone, order)
    local here = state.cached_pos
    if not zone or not here or type(here.x) ~= "number" then return false end
    local px, py, pz, d, nxt = path_nearest(zone, here.x, here.y)
    if not px then return false end
    if d > DRIFT_MAX then gp.rejoin = true end
    if not gp.rejoin then return false end
    if d <= PATH_KEEP then
        gp.rejoin = false
        -- Resume from the node the nearest segment leads to.
        if type(order) == "table" and #order > 0 then
            for p = 1, #order do
                if order[p] == nxt then state.grind.move = p break end
            end
        else
            state.grind.move = nxt
        end
        return false
    end
    if movement.is_quiet() or movement.in_combat_movement() then return true end
    local same = gp.rx and math.abs(gp.rx - px) < 2 and math.abs(gp.ry - py) < 2
    if movement.is_moving() and same then
        state.set_note("Grind", string.format("Back to the path  %.0f yd", d))
        return true
    end
    gp.rx, gp.ry = px, py
    state.set_note("Grind", string.format("Back to the path  %.0f yd", d))
    movement.nav_to({ x = px, y = py, z = pz }, true)
    return true
end

function grind.kill_mobs(player)
    if not player then
        return
    end
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        return
    end
    local zone = current_zone(player)
    local mobs = zone and zone.mobs or nil
    -- Only what is within the class's attack distance (2.230.0); the nearest
    -- valid mob wins. Until then the path is walked.
    local pull = pull_yards(player)
    local enemies = targeting.find_mobs(player, mobs, pull, true)
    local unit = targeting.nearest(player, enemies)
    if unit then
        targeting.set_current(unit, "kill")
        state.grind.step = 2
        state.grind.black_until = izi.now() + gui.slider("max_kill", 60)
        state.set_note("Grind", "Closing")
        return
    end
    if not zone or type(zone.coords) ~= "table" then
        state.set_note("Grind", "No grind path for this race/level")
        return
    end
    local coords = zone.coords
    if type(movement.plan_grind_route) == "function" then
        movement.plan_grind_route(coords)
    end

    local order = nil
    if type(movement.grind_visit_order) == "function" then
        order = movement.grind_visit_order()
    end
    -- Back onto the path first: after a fight, or drifted off it (2.230.0).
    if rejoin_path(zone, order) then return end
    local using_order = type(order) == "table" and #order > 0
    local n
    local pos
    if using_order then
        n = #order
        if state.grind.move > n then
            state.grind.move = 1
        end
        local coord_i = order[state.grind.move]
        if type(coord_i) == "number" then
            pos = (node_row(zone, coord_i))
        end
        if not pos then
            pos, n = node_row(zone, state.grind.move)
            using_order = false
        end
    else
        pos, n = node_row(zone, state.grind.move)
        if not pos then
            state.set_note("Grind", "No grind path for this race/level")
            return
        end
        snap_grind_node(zone, n, state.cached_pos)
        pos, n = node_row(zone, state.grind.move)
    end
    if not pos then
        return
    end
    local function skip_node(why)
        core.log_warning("[Master Farmer - Grindbot] Grind skip node " .. tostring(state.grind.move) .. " (" .. tostring(why) .. ")")
        state.grind.move = state.grind.move + 1
        if state.grind.move > n then
            state.grind.move = 1
        end
        movement.clear_fail()
    end
    if movement.arrived(pos, 2) then
        if gui.is_on("random_path") and n > 2 then
            if math.random(1, 10) > 5 then
                state.grind.move = state.grind.move + 1
            else
                state.grind.move = state.grind.move + 2
            end
        else
            state.grind.move = state.grind.move + 1
        end
        if state.grind.move > n then
            -- LOOP PATH (2.151.0): a profile that is not a loop stops at its
            -- last node unless "Loop Path" forces a replay. Fights still run.
            if zone.path and zone.path.loop == false and not gui.is_on("path_loop") then
                state.grind.move = n
                state.grind.finished = true
            else
                state.grind.move = 1
            end
            if zone.path then lap_pending = math.min(lap_pending + 1, 1) end
        end
        return
    end
    if state.grind.finished and gui.is_on("path_loop") then
        state.grind.finished = false
        state.grind.move = 1
    end
    if state.grind.finished then
        state.set_note("Grind", tostring(zone.name or "Path") .. " finished - tick Loop Path to replay")
        return
    end
    if type(movement.node_reachable) == "function" and movement.node_reachable(pos, state.grind.move) == false then
        skip_node("unreachable")
        return
    end
    if movement.is_blocked(pos) or movement.last_fail_offmesh() then
        skip_node(movement.last_fail_reason() or "blacklist")
        return
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        state.set_note("Grind", "Nav settle")
        return
    end
    if movement.is_moving() then
        state.set_note("Grind", string.format("%s  node %d / %d", tostring(zone.name or "Patrol"), state.grind.move, n))
        return
    end
    state.set_note("Grind", string.format("%s  node %d / %d", tostring(zone.name or "Patrol"), state.grind.move, n))
    movement.nav_to(pos, true)
end

function grind.tick(player)
    if not player then
        return
    end
    -- A fight just ended: walk back to the path before the patrol goes on.
    if gp.prev_step == 2 and state.grind.step == 1 then gp.rejoin = true end
    gp.prev_step = state.grind.step
    -- The whole fight, not only the unit in the target frame (2.174.0).
    -- Adds that die while another mob is focused are still queued, and the
    -- next pull waits until those corpses are looted.
    remember_fight(player)
    queue_our_corpses(player)
    -- Attacked: fight back now (2.38.0) - every tick, before the rest check
    -- and whether or not there is a target. With no target the old check only
    -- ran when the periodic scan came round, and the route kept walking.
    local attacked = false
    do
        local cur_guid = (state.target.kind == "kill") and state.target.guid or nil
        local range = math.max(gui.slider("fight_back_yards", 30), targeting.THREAT_RANGE or 40)
        local attacker = targeting.attacker_to_switch(player, cur_guid, range)
        if attacker then
            targeting.combat_active()
            targeting.set_current(attacker, "kill")
            state.grind.step = 2
            state.grind.black_until = izi.now() + gui.slider("max_kill", 60)
            state.set_note("Grind", "Fight back")
            attacked = true
        elseif state.grind.step == 1 and targeting.combat_hold(player) then
            -- A corpse waiting outranks the sit: loot.tick walks it.
            local ok_l, lt = pcall(require, "loot")
            if not (ok_l and type(lt) == "table" and type(lt.has_work) == "function" and lt.has_work(player)) then
                if movement and type(movement.nav_stop) == "function" then
                    movement.nav_stop()
                end
                state.set_note("Grind", "Holding - combat not over")
                return
            end
        end
    end
    if not attacked then
        local ok_l, lt = pcall(require, "loot")
        if ok_l and type(lt) == "table" and type(lt.has_work) == "function" and lt.has_work(player)
            and (type(targeting.attackers) ~= "function" or targeting.attackers(player) <= 0) then
            if type(movement.combat_release) == "function" then
                movement.combat_release()
            end
            state.set_note("Grind", "Looting before the next pull")
            return
        end
    end
    if not attacked and healing and type(healing.is_resting) == "function" and healing.is_resting() then
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        pcall(function()
            core.input.stop_attack()
        end)
        return
    end
    local now = izi.now()

    if state.grind.step == 1 then
        if now < state.grind.scan_until then
            grind.kill_mobs(player)
            return
        end
        state.grind.scan_until = now + SCAN_GAP
        local in_combat = safe(function() return player:is_in_combat() end) == true
        local hp = safe(function() return player:get_health_percentage() end) or 100
        local want_back = in_combat
            or (gui.is_on("fight_back") and hp <= gui.slider("fight_back_hp", 70))
        if want_back then
            local pack = targeting.combat_scan(player, gui.slider("fight_back_yards", 30))
            local unit = targeting.nearest(player, pack)
            if unit then
                targeting.set_current(unit, "kill")
                state.grind.step = 2
                state.grind.black_until = now + gui.slider("max_kill", 60)
                state.set_note("Grind", "Fight back")
                return
            end
        end
        grind.kill_mobs(player)
        return
    end

    -- Whatever is attacking the player comes before the target being chased
    -- (2.37.0): switch to it, and keep the current target only while it is
    -- one of the attackers (or nothing is attacking).
    do
        local cur_guid = (state.target.kind == "kill") and state.target.guid or nil
        local attacker = targeting.attacker_to_switch(player, cur_guid, gui.slider("fight_back_yards", 30))
        if attacker then
            targeting.set_current(attacker, "kill")
            state.grind.black_until = now + gui.slider("max_kill", 60)
            state.set_note("Grind", "Fight back")
        end
    end

    local unit = state.target.unit
    -- Valid first, always (2.32.0): see quest/engine fight_unit. An engaged
    -- target gone invalid is recorded as a kill from its saved GUID.
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
        movement.nav_stop()
        movement.combat_release()
        state.reset_target()
        state.grind.step = 1
        return
    end
    if safe(function() return unit:is_dead() end) == true
        or safe(function() return unit:is_dead_or_ghost() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        local ok_l, loot = pcall(require, "loot")
        if ok_l and type(loot) == "table" and type(loot.note_kill) == "function" then
            loot.note_kill(unit)
        end
        movement.nav_stop()
        movement.combat_release()
        state.reset_target()
        state.grind.step = 1
        return
    end
    if now > state.grind.black_until and state.target.kind == "kill" then
        state.mark_killed(state.target.guid)
        movement.nav_stop()
        movement.combat_release()
        state.reset_target()
        state.grind.step = 1
        return
    end
    if safe(function() return unit:is_dead_or_ghost() end) == true or safe(function() return unit:is_dead() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        movement.nav_stop()
        movement.combat_release()
        state.reset_target()
        state.grind.step = 1
        return
    end

    local dist = safe(function() return player:distance_to(unit) end) or 99
    if dist > (targeting.MAX_RANGE or 300) then
        movement.combat_release()
        state.reset_target()
        state.grind.step = 1
        return
    end
    -- With the Crash Recorder ticked, keep it running for the whole fight
    -- (2.68.0): the crashes of 2026-09-27 came 16 s and 67 s into grinding,
    -- mid-fight, and the Start burst alone may not cover the next one.
    if probe_el and gui.is_on("crash_recorder") and type(probe_el.arm) == "function" then
        pcall(probe_el.arm, "grind fight")
    end
    xprobe("g:ensure_target")
    targeting.ensure_target(player, unit)
    local yards = 30
    if type(rotation.combat_range) == "function" then
        yards = rotation.combat_range(player)
    end
    if type(yards) ~= "number" or yards < 1 then
        yards = 30
    end
    -- No way closer (behind a mountain): blacklisted, back to the path (2.230.0).
    if type(targeting.approach_stuck) == "function" and targeting.approach_stuck(player, unit, yards) then
        movement.nav_stop()
        movement.combat_release()
        state.reset_target()
        state.grind.step = 1
        state.set_note("Grind", "Skip unreachable")
        return
    end
    xprobe("g:auto_attack")
    targeting.start_auto_attack(player, unit)
    xprobe("g:combat_engage")
    if not movement.combat_engage(player, unit, yards) then
        if state.is_unreachable and state.is_unreachable(state.target.guid) then
            movement.combat_release()
            state.reset_target()
            state.grind.step = 1
            state.set_note("Grind", "Skip unreachable")
            return
        end
        xprobe("g:face")
        movement.face(unit)
        state.set_note("Grind", "Closing")
        xprobe("g:scan")
        local closing_pack = targeting.combat_scan(player, yards)
        xprobe("g:rotation.tick closing")
        rotation.tick(player, unit, { enemies = closing_pack, no_move = true })
        xprobe("g:rotation.tick done")
        return
    end
    xprobe("g:face")
    movement.face(unit)
    xprobe("g:scan")
    local pack = targeting.combat_scan(player, yards)
    state.set_note("Grind", "Killing")
    xprobe("g:rotation.tick")
    rotation.tick(player, unit, { enemies = pack, no_move = true })
    xprobe("g:rotation.tick done")
end

return grind
