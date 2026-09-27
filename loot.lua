-- ============================================================================
-- Master Farmer - Grindbot
-- Auto loot - a GUID queue, resolved fresh every tick
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.79.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- HOW IT WORKS
--   1. An engine that sees its target die calls loot.note_kill(unit) in that
--      same tick. The corpse's GUID and position go on the queue, so
--      loot.has_work() is already true before the engine considers its next
--      pull. (2.31.0 found corpses by scanning AFTER the kill: loot.tick ran
--      before the engine noticed the death, cached "no corpse", and the
--      engine pulled the next mob in the same tick - nothing was looted.)
--   2. loot.tick resolves the queued GUID with
--      core.object_manager.get_object_from_guid every tick. No object handle
--      is ever kept between ticks: the API says to store the GUID and resolve
--      it fresh, and a stale handle is a native read of freed memory.
--   3. It walks to within LOOT_REACH, stops, and calls
--      core.input.loot_object(corpse, true) - auto loot, which takes the
--      whole window in one call. At most one attempt per FIRE_GAP, MAX_FIRES
--      in all. The job is done when the corpse stops being lootable; a loot
--      window left open is closed with core.input.close_loot.
--   4. Anything attacking the player comes first: the tick steps aside and
--      the engine fights. Each corpse gets ENTRY_TIMEOUT, and the queue
--      forgets entries after ENTRY_TTL, so looting can never stall the bot.
--   5. A fallback scan once per SCAN_GAP queues any lootable corpse within
--      SCAN_YARDS - kills the engines did not report. can_be_looted is only
--      true for the player holding loot rights, so these are ours.
--
-- The whole feature is the "Auto Loot Corpses" checkbox on the General tab.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local inventory_helper = require("common/utility/inventory_helper")

local gui = require("gui")
local state = require("state")
local targeting = require("targeting")
local movement = require("movement")

local loot = {}

local LOOT_REACH = 3.5        -- yards: close enough to loot
local FIRE_GAP = 1.0          -- seconds between loot_object attempts
local SETTLE = 0.6            -- seconds after an attempt before judging it
local MAX_FIRES = 3           -- attempts per corpse
local ENTRY_TIMEOUT = 15.0    -- seconds a corpse may take, walk included
local ENTRY_TTL = 120.0       -- seconds a queued corpse is remembered
-- 30 SECONDS AND MOVE ON (2.55.0): a corpse not looted within GIVE_UP of the
-- kill is dropped - whatever held it up - and the bot carries on questing.
-- It is then IGNORED for IGNORE_FOR, so the fallback scan cannot queue it
-- again and restart the wait.
local GIVE_UP = 30.0
local IGNORE_FOR = 600.0
local ignored = {}            -- guid -> ignored until
-- The game sets a corpse's lootable flag a moment AFTER the mob dies. A corpse
-- queued in the kill tick used to be dropped on the next tick as "never ours"
-- because can_be_looted was still false (2.38.0).
local FLAG_GRACE = 3.0
local QUEUE_MAX = 8
local SCAN_GAP = 1.0          -- seconds between fallback corpse scans
local SCAN_YARDS = 40        -- the combat lock's range: every fight's corpses are in it

local queue = {}              -- { guid, x, y, z, added, started, fires, fired_t }
local next_scan = 0
-- (fallback-scanned corpses are not "mine": they are only looted when the
-- game says they are lootable)
local close_at = nil          -- when to close a loot window left open

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

local function elog_probe(tag)
    local ok, elog = pcall(require, "errorlog")
    if ok and type(elog) == "table" and type(elog.probe) == "function" then
        elog.probe(tag)
    end
end

--- A loot breadcrumb in scripts_log (errorlog.trail skips repeats).
local function ltrail(fmt, ...)
    local ok, elog = pcall(require, "errorlog")
    if ok and type(elog) == "table" and type(elog.trail) == "function" then
        elog.trail("loot", fmt, ...)
    end
end

--- A vendor trip under way - including a Hearthstone trip, whose cast a
--- walk to a corpse would cancel.
local function vendor_busy()
    local v = package.loaded["vendor"]
    if type(v) == "table" and type(v.is_busy) == "function" then
        return v.is_busy() == true
    end
    return state.vendor and state.vendor.active == true
end

local function enabled()
    return gui and gui.is_on("loot") == true
end

local function bags_too_full()
    if not inventory_helper or type(inventory_helper.get_total_free_slots) ~= "function" then
        return false
    end
    local ok, free = pcall(inventory_helper.get_total_free_slots, inventory_helper)
    if not ok or type(free) ~= "number" then
        return false
    end
    return free <= 1
end

local function resting()
    local ok_h, healing = pcall(require, "healing")
    return ok_h and healing and type(healing.is_resting) == "function" and healing.is_resting() == true
end

--- The corpse behind a GUID, freshly resolved, or nil when it is gone.
---
--- BY SCANNING (2.46.0). core.object_manager.get_object_from_guid hands its
--- string to the client's UNIT-TOKEN resolver ("target", "nameplate7"...). A
--- corpse has no unit token - dead mobs have no nameplate and the bot has
--- dropped its target - so it came back nil, and every queued corpse was
--- dropped as "gone" on the next tick. The visible-object list (targeting's
--- per-tick cache) is searched for the GUID instead; the token resolver is
--- only tried first, and only trusted when its object carries the same GUID.
local function resolve(guid)
    if type(guid) ~= "string" or guid == "" then
        return nil
    end
    local obj = safe(function() return core.object_manager.get_object_from_guid(guid) end)
    if obj and safe(function() return obj:is_valid() end) == true
        and safe(function() return obj:get_guid() end) == guid then
        return obj
    end
    local list = targeting.visible_objects and targeting.visible_objects() or nil
    if type(list) ~= "table" then
        return nil
    end
    for i = 1, #list do
        local o = list[i]
        if o and safe(function() return o:is_valid() end) == true
            and safe(function() return o:get_guid() end) == guid then
            return o
        end
    end
    return nil
end

--- has_loot() said NO in so many words (not merely unknown).
local function empty(obj)
    local ok, has = pcall(obj.has_loot, obj)
    return ok and has == false
end

local function lootable(obj)
    local ok, can = pcall(obj.can_be_looted, obj)
    if ok and type(can) == "boolean" then
        return can
    end
    local ok2, has = pcall(obj.has_loot, obj)
    return ok2 and has == true
end

local function find_entry(guid)
    for i = 1, #queue do
        if queue[i].guid == guid then
            return i
        end
    end
    return nil
end

local function drop(i)
    table.remove(queue, i)
end

--- Queue a corpse by GUID. `mine` marks the bot's own kills: those always
--- get a loot attempt, whatever the lootable flag says. Returns true when
--- it was added.
local function enqueue(guid, pos, mine)
    if type(guid) ~= "string" or guid == "" then
        return false
    end
    if (ignored[guid] or 0) > izi.now() then
        return false
    end
    local at = find_entry(guid)
    if at then
        if mine then
            queue[at].mine = true
        end
        return false
    end
    if #queue >= QUEUE_MAX then
        table.remove(queue, 1)
    end
    local now = izi.now()
    queue[#queue + 1] = {
        guid = guid,
        x = pos and pos.x or nil, y = pos and pos.y or nil, z = pos and pos.z or nil,
        added = now, started = nil, fires = 0, fired_t = -1e9, mine = mine == true,
    }
    ltrail("queued %s (%s)", guid, mine and "our kill" or "found nearby")
    return true
end

-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------

--- An engine's target just died: queue its corpse. Call while the unit is
--- still valid - its GUID and position are read here, once.
function loot.note_kill(unit)
    if not unit or not enabled() then
        return false
    end
    if safe(function() return unit:is_valid() end) ~= true then
        return false
    end
    local guid = safe(function() return unit:get_guid() end)
    local pos = safe(function() return unit:get_position() end)
    return enqueue(guid, pos, true)
end

--- Queue a corpse from a saved GUID and position - for a target that went
--- invalid at the moment of death, when there is no handle left to read.
function loot.note_kill_guid(guid, pos)
    if not enabled() then
        return false
    end
    return enqueue(guid, pos, true)
end

--- Is anything queued that is still worth going to?
function loot.has_work(player)
    if not enabled() or #queue == 0 then
        return false
    end
    -- No resting gate (2.46.0): loot comes BEFORE eating, not after.
    -- No full-bags gate (2.47.0): stackables, quest items and gold still
    -- loot into full bags, and full bags switched looting off altogether.
    if vendor_busy() then
        return false
    end
    local now = izi.now()
    for i = #queue, 1, -1 do
        local e = queue[i]
        if (now - e.added) > GIVE_UP then
            ltrail("done %s: gave up after %.0f s", e.guid, GIVE_UP)
            ignored[e.guid] = now + IGNORE_FOR
            drop(i)
        elseif (now - e.added) > ENTRY_TTL then
            drop(i)
        end
    end
    return #queue > 0
end

--- Forget the queue (Stop, mode change).
function loot.reset()
    queue = {}
    ignored = {}
    close_at = nil
end

local function under_attack(player)
    if safe(function() return player:is_in_combat() end) ~= true then
        return false
    end
    -- The combat lock's threats: anything on the player OR the pet.
    local pack = targeting.threats(player, targeting.THREAT_RANGE or 40)
    return type(pack) == "table" and #pack > 0
end

local function fallback_scan(player, now)
    if now < next_scan then
        return
    end
    next_scan = now + SCAN_GAP
    local list = targeting.find_corpses(player, SCAN_YARDS)
    if type(list) ~= "table" then
        return
    end
    for i = 1, #list do
        local c = list[i]
        if safe(function() return c:is_valid() end) == true then
            local guid = safe(function() return c:get_guid() end)
            -- A corpse the bot targeted to kill is its own kill: it is queued
            -- and gets a loot attempt whatever the lootable flag says. Any
            -- other corpse only when the game says it is lootable.
            local mine = guid and ((type(state.was_engaged) == "function" and state.was_engaged(guid))
                or (type(state.was_killed) == "function" and state.was_killed(guid))) or false
            local can_c = lootable(c)
            -- Plainly empty (not lootable, and has_loot says no): nothing to queue.
            if (mine or can_c) and not (not can_c and empty(c)) then
                local pos = safe(function() return c:get_position() end)
                enqueue(guid, pos, mine == true)
            end
        end
    end
end

--- Queue the current kill target's corpse the moment it dies (2.48.0).
---
--- Kills were only detected inside the quest / grind tick, which runs last
--- in the cascade - a rest starting as combat ended claimed the tick first,
--- the kill was never seen, and its corpse was later found by the scan as
--- "not ours" and dropped. This runs first, every tick.
local function watch_target()
    local t = state.target
    if not t or t.kind ~= "kill" or not t.guid then
        return
    end
    local u = t.unit
    if u and safe(function() return u:is_valid() end) == true then
        if safe(function() return u:is_dead() end) == true then
            loot.note_kill(u)
        end
    elseif find_entry(t.guid) == nil then
        loot.note_kill_guid(t.guid, t.x and { x = t.x, y = t.y, z = t.z } or nil)
    end
end

--- One bot tick of looting. Returns true while it owns the tick.
function loot.tick(player)
    if not player or not enabled() then
        return false
    end
    watch_target()
    local now = izi.now()

    -- A loot window left open after an auto loot.
    if close_at and now >= close_at then
        close_at = nil
        local n = safe(function() return core.game_ui.get_loot_item_count() end)
        if type(n) == "number" and n > 0 then
            -- Auto loot left items behind: take each slot (0 based), then
            -- close the window.
            for i = 0, n - 1 do
                pcall(function() core.input.loot_item(i) end)
            end
            pcall(function() core.input.close_loot() end)
        end
    end

    if vendor_busy() then
        return false
    end
    if safe(function() return player:is_dead() end) == true then
        return false
    end
    -- Fighting comes first; the engine's fight-back handles it.
    if under_attack(player) then
        return false
    end

    fallback_scan(player, now)
    if not loot.has_work(player) then
        return false
    end

    -- Nearest queued corpse that still exists and can still be looted.
    -- The best ENTRY is kept, not its index (2.50.0): dropping a lower entry
    -- later in this backward pass shifts every index above it, and
    -- queue[best_i] came back nil - "attempt to index local 'e'" every tick,
    -- which aborted the whole cascade (quest, NPCs, everything) behind it.
    local best_e, best_obj, best_d = nil, nil, nil
    for i = #queue, 1, -1 do
        local e = queue[i]
        local obj = resolve(e.guid)
        local why = nil
        if (now - e.added) > GIVE_UP then
            why = string.format("gave up after %.0f s", GIVE_UP)
            ignored[e.guid] = now + IGNORE_FOR
        elseif obj == nil then
            why = "corpse not found"
        elseif safe(function() return obj:is_dead() end) ~= true then
            why = "not dead"
        elseif e.started and (now - e.started) > ENTRY_TIMEOUT then
            why = "timed out"
        elseif e.fires >= MAX_FIRES and (now - e.fired_t) > SETTLE then
            why = "attempts used up"
        end
        local gone = why ~= nil
        local can = (not gone) and lootable(obj)
        if can then
            e.seen_lootable = true
        end
        if not gone then
            -- ALREADY LOOTED (2.56.0). Seen lootable once and not any more:
            -- someone emptied it - the bot, or the player by hand. Done, no
            -- walk and no attempt.
            if not can and e.seen_lootable then
                gone, why = true, "already looted"
            -- Nothing on it, in so many words, once the flag has had its grace.
            elseif (now - e.added) > FLAG_GRACE and empty(obj) then
                gone, why = true, "empty"
            -- After an attempt: un-lootable or empty means it worked.
            elseif e.fires > 0 and (now - e.fired_t) > SETTLE and (not can or empty(obj)) then
                gone, why = true, "looted"
            elseif not can and not e.mine and (now - e.added) > FLAG_GRACE then
                gone, why = true, "not lootable"
            end
        end
        if gone then
            ltrail("done %s: %s after %d attempt(s)", e.guid, tostring(why), e.fires)
            -- Every finished corpse is remembered (2.56.0): the fallback scan
            -- used to find a looted corpse again - the flag lags, or items
            -- that are not ours stay on it - and queue it all over again.
            ignored[e.guid] = now + IGNORE_FOR
            drop(i)
        else
            local d = safe(function() return player:distance_to(obj) end)
            if type(d) == "number" and (best_d == nil or d < best_d) then
                best_e, best_obj, best_d = e, obj, d
            end
        end
    end
    if not best_e then
        return false
    end

    local e = best_e
    if not lootable(best_obj) and (now - e.added) <= FLAG_GRACE then
        -- Fresh corpse, flag not set yet: walk over, but do not fire yet.
        if best_d <= LOOT_REACH then
            movement.nav_stop()
            state.set_note("Loot", "Waiting for the corpse to be lootable")
            return true
        end
    end
    e.started = e.started or now

    if best_d > LOOT_REACH then
        local pos = safe(function() return best_obj:get_position() end)
        if pos then
            elog_probe("loot:walk")
            -- The fight is over (under_attack said so): give the player
            -- back from combat movement so the walk is not refused.
            if type(movement.in_combat_movement) == "function" and movement.in_combat_movement()
                and type(movement.combat_release) == "function" then
                movement.combat_release()
            end
            if not movement.is_moving() then
                movement.nav_to(pos, true)
            end
            state.set_note("Loot", string.format("Walking to corpse  %.0fy", best_d))
            return true
        end
        for k = #queue, 1, -1 do
            if queue[k] == e then
                drop(k)
                break
            end
        end
        return false
    end

    movement.nav_stop()
    if (now - e.fired_t) >= FIRE_GAP and e.fires < MAX_FIRES then
        e.fires = e.fires + 1
        e.fired_t = now
        elog_probe("loot:fire")
        ltrail("loot attempt %d on %s at %.1f yd", e.fires, e.guid, best_d)
        pcall(function() core.input.loot_object(best_obj, true) end)
        close_at = now + 1.5
    end
    state.set_note("Loot", "Looting")
    return true
end

return loot
