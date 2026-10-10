-- ============================================================================
-- Master Farmer - Grindbot
-- Death run — release, path graveyard to corpse, retrieve
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.269.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

local gui = require("gui")
local movement = require("movement")
local state = require("state")
local geometry = require("geometry")

local death = {}

local RELEASE_GAP = 3.0
-- CLOSE ENOUGH TO REVIVE (2.256.0). The walk stopped 32 yd from the "safe
-- spot" - up to ~14 yd beside the corpse when mobs stand on it - so the ghost
-- could stand ~46 yd from the corpse, out of reach, on "Retrieving corpse"
-- for good. The distance is now to the CORPSE; the ghost walks to within
-- RETRIEVE_STEPS[1] yd, and every RETRIEVE_TRIES refused revives it walks
-- closer (10 yd, then onto the corpse).
local RETRIEVE_RANGE = 20.0
local RETRIEVE_STEPS = { 20.0, 10.0, 4.0 }
local RETRIEVE_TRIES = 3
local HOSTILE_RANGE = 8.0
local SAFE_OFFSET = 10.0
local LEVEL_GAP = 6          -- mobs this far below the player are not a threat
local RETRIEVE_GAP = 1.5

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
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


local function pause_path()
    local ok, path_runner = pcall(require, "path_runner")
    if ok and path_runner and type(path_runner.pause) == "function" then
        path_runner.pause()
    end
end

local function resume_path()
    local ok, path_runner = pcall(require, "path_runner")
    if ok and path_runner and type(path_runner.resume) == "function" then
        path_runner.resume()
    end
end

local function as_vec3(pos)
    if type(pos) ~= "table" then
        return nil
    end
    local x, y, z = pos.x, pos.y, pos.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    if x == 0 and y == 0 and z == 0 then
        return nil
    end
    -- NaN or infinity (2.201.0): the corpse position read "inf" right after
    -- the release on WoW Forever, and the run asked Sentinel for it.
    if x ~= x or y ~= y or z ~= z
        or math.abs(x) > 1e7 or math.abs(y) > 1e7 or math.abs(z) > 1e7 then
        return nil
    end
    return vec3.new(x, y, z)
end

local function corpse_position()
    local raw = safe(function()
        return core.game_ui.get_corpse_position()
    end)
    local vec = as_vec3(raw)
    if vec then
        state.dead.corpse = vec
        return vec
    end
    -- The client gave nothing usable (inf, 0,0,0): the last known corpse,
    -- else where the character died (2.201.0) - the body stays where it fell.
    return as_vec3(state.dead.corpse) or as_vec3(state.dead.died_pos)
end

local function dist_to(pos)
    local here = state.cached_pos
    if not here or not pos then
        return nil
    end
    -- vec3:dist_to, not sqrt of the squares by hand.
    local d = geometry.distance(here, pos)
    if type(d) == "number" then
        return d
    end
    -- A position the vector helper could not read. Say "far" rather than
    -- "here": a corpse run must not think it has arrived because a
    -- coordinate was missing.
    return math.huge
end

--- Is anything near `pos` that would actually threaten a resurrection?
---
--- `player_level` is optional. When supplied, mobs more than LEVEL_GAP levels
--- below the player are ignored: a grey mob next to the corpse is not a threat,
--- and treating it as one forces a pointless relocation every single death in
--- a low-level zone.
local function hostiles_near(pos, yards, player_level)
    if not pos then
        return false
    end
    local list = safe(function()
        return unit_helper:get_enemy_list_around(pos, yards, true, false, false, false)
    end)
    if type(list) ~= "table" then
        return false
    end
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true then
            if call(u.is_dead_or_ghost, u) ~= true then
                if call(u.is_player, u) ~= true then
                    if call(u.is_dummy, u) ~= true then
                        local ignore = false
                        if type(player_level) == "number" then
                            local lvl = call(u.get_level, u)
                            if type(lvl) == "number" and (player_level - lvl) > LEVEL_GAP then
                                ignore = true
                            end
                        end
                        if not ignore then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

--- Snap a candidate onto the ground. Offsetting x/y while keeping the corpse's
--- z puts the point inside terrain on any slope, which then fails to path to.
local function snapped(x, y, hint_z)
    local z = hint_z
    if type(movement.ground_z) == "function" then
        local got = safe(function() return movement.ground_z(x, y, hint_z) end)
        if type(got) == "number" and got == got then
            z = got
        end
    end
    return vec3.new(x, y, z)
end

local function safe_retrieve_pos(corpse, player_level)
    if not corpse then
        return nil
    end
    if not hostiles_near(corpse, HOSTILE_RANGE, player_level) then
        return corpse
    end
    local offsets = {
        { SAFE_OFFSET, SAFE_OFFSET },
        { -SAFE_OFFSET, SAFE_OFFSET },
        { -SAFE_OFFSET, -SAFE_OFFSET },
        { SAFE_OFFSET, -SAFE_OFFSET },
    }
    for i = 1, #offsets do
        local candidate = snapped(corpse.x + offsets[i][1], corpse.y + offsets[i][2], corpse.z)
        if not hostiles_near(candidate, HOSTILE_RANGE, player_level) then
            return candidate
        end
    end
    return corpse
end

local function dtrail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "death", fmt, ...)
    end
end

local function dist2d(a, b)
    if not a or not b or type(a.x) ~= "number" or type(b.x) ~= "number" then return nil end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

local function run_to(dest)
    if not dest then
        return
    end
    if movement.last_fail_offmesh() then
        movement.nav_to(dest, true)
        movement.clear_fail()
        return
    end
    movement.nav_to(dest)
end

function death.is_down(player)
    if not player then
        return false
    end
    if safe(function() return player:is_dead_or_ghost() end) == true then
        return true
    end
    if safe(function() return player:is_dead() end) == true then
        return true
    end
    if safe(function() return player:is_ghost() end) == true then
        return true
    end
    return false
end

--- Blacklist whatever we were fighting when we died.
---
--- The reference bot does this so the target selector stops handing back the
--- exact mob that just killed us - otherwise the bot corpse-runs, res-es, walks
--- straight back into the same pull and dies again in a loop. state already has
--- the mechanism; movement/combat.lua uses it for unreachable mobs.
local function blacklist_killer()
    if type(state.mark_unreachable) ~= "function" then
        return
    end
    local unit = safe(function() return movement.combat_unit() end)
    if not unit then
        return
    end
    local guid = safe(function() return unit:get_guid() end)
    if guid == nil then
        return
    end
    state.mark_unreachable(guid)
    core.log("[Master Farmer - Grindbot] Blacklisted the mob that killed us: " .. tostring(guid))
end

local function begin_death()
    if state.dead.waiting then
        return
    end
    -- 2.247.0: the killer, read before blacklist_killer / reset_target
    local killer = safe(function() return movement.combat_unit() end)
    blacklist_killer()
    state.dead.waiting = true
    state.dead.corpse = nil
    -- Where the body fell (2.201.0), recorded before the release: the corpse
    -- position fallback when get_corpse_position answers inf. Not as a ghost
    -- (a reload mid corpse run): the ghost stands at the graveyard.
    state.dead.died_pos = nil
    local me = safe(function() return izi.me() end)
    if me and safe(function() return me:is_ghost() end) ~= true then
        local p = safe(function() return me:get_position() end)
        if as_vec3(p) then
            state.dead.died_pos = { x = p.x, y = p.y, z = p.z }
        end
    end
    -- DEATH ZONES (2.247.0): 3 deaths to the same enemy in one area -> that
    -- area is avoided for 10+ minutes (deathzones.lua). Only a real death
    -- spot: a ghost after a reload stands at the graveyard.
    if state.dead.died_pos then
        local ok_dz, dz = pcall(require, "deathzones")
        if ok_dz and type(dz) == "table" and type(dz.record_death) == "function" then
            pcall(dz.record_death, killer, state.dead.died_pos)
        end
    end
    state.dead.retrieve_at = 0
    state.dead.retrieve_tries = 0
    state.dead.step_logged = nil
    state.grind.step = 1
    state.reset_target()
    if type(movement.set_resting) == "function" then
        movement.set_resting(false)
    end
    pause_path()
    movement.nav_stop()
end

local function end_death()
    if not state.dead.waiting then
        return
    end
    state.dead.waiting = false
    state.dead.corpse = nil
    state.dead.died_pos = nil
    resume_path()
end

function death.tick(player)
    if not gui.is_started() then
        return false
    end
    if not death.is_down(player) then
        end_death()
        return false
    end

    begin_death()

    local now = izi.now()
    local is_ghost = safe(function() return player:is_ghost() end) == true
    if not is_ghost then
        if (now - (state.dead.released_at or 0)) >= RELEASE_GAP then
            state.dead.released_at = now
            pcall(function()
                core.input.release_spirit()
            end)
        end
        state.set_note("Death", "Releasing spirit")
        return true
    end

    local corpse = corpse_position()
    if not corpse then
        state.set_note("Death", "Waiting for corpse position")
        return true
    end

    local my_level = safe(function() return player:get_level() end)
    local dest = safe_retrieve_pos(corpse, my_level)
    local d = dist_to(corpse) or dist_to(dest)
    if type(d) ~= "number" then
        run_to(dest)
        state.set_note("Death", "Running to corpse")
        return true
    end

    local step = math.min(#RETRIEVE_STEPS, 1 + math.floor((state.dead.retrieve_tries or 0) / RETRIEVE_TRIES))
    local reach = RETRIEVE_STEPS[step] or RETRIEVE_RANGE
    if d > reach then
        -- the safe spot while it is inside the reach, else straight to the corpse
        local dd = dist_to(dest)
        local go = (step == 1 and dest and (dist2d(dest, corpse) or 0) < reach) and dest or corpse
        run_to(go)
        state.set_note("Death", string.format("Corpse  %.0f yd", d))
        if dd and step > 1 and state.dead.step_logged ~= step then
            state.dead.step_logged = step
            dtrail("revive refused %d times at %.0f yd - walking to %.0f yd of the corpse",
                state.dead.retrieve_tries or 0, d, reach)
        end
        return true
    end

    movement.nav_stop()
    local delay = safe(function()
        return core.game_ui.get_resurrect_corpse_delay()
    end) or 0
    if type(delay) == "number" and delay > 0 then
        state.set_note("Death", string.format("Retrieve in %.0fs", delay))
        return true
    end
    if (now - (state.dead.retrieve_at or 0)) >= RETRIEVE_GAP then
        state.dead.retrieve_at = now
        state.dead.retrieve_tries = (state.dead.retrieve_tries or 0) + 1
        dtrail("revive at %.0f yd of the corpse (try %d)", d, state.dead.retrieve_tries)
        pcall(function()
            core.input.resurrect_corpse()
        end)
    end
    state.set_note("Death", "Retrieving corpse")
    return true
end

return death
