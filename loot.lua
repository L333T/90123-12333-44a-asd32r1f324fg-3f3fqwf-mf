-- ============================================================================
-- Master Farmer - Grindbot
-- Auto loot - a GUID queue, resolved fresh every tick
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.47.0
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
        if (now - queue[i].added) > ENTRY_TTL then
            drop(i)
        end
    end
    return #queue > 0
end

--- Forget the queue (Stop, mode change).
function loot.reset()
    queue = {}
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
        if safe(function() return c:is_valid() end) == true and lootable(c) then
            local guid = safe(function() return c:get_guid() end)
            local pos = safe(function() return c:get_position() end)
            enqueue(guid, pos, false)
        end
    end
end

--- One bot tick of looting. Returns true while it owns the tick.
function loot.tick(player)
    if not player or not enabled() then
        return false
    end
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
    local best_i, best_obj, best_d = nil, nil, nil
    for i = #queue, 1, -1 do
        local e = queue[i]
        local obj = resolve(e.guid)
        local why = nil
        if obj == nil then
            why = "corpse not found"
        elseif safe(function() return obj:is_dead() end) ~= true then
            why = "not dead"
        elseif e.started and (now - e.started) > ENTRY_TIMEOUT then
            why = "timed out"
        elseif e.fires >= MAX_FIRES and (now - e.fired_t) > SETTLE then
            why = "attempts used up"
        end
        local gone = why ~= nil
        if not gone and not lootable(obj) then
            -- Looted (after a fire), or never ours to loot - judged only once
            -- the flag has had FLAG_GRACE to appear. The bot's own kills get
            -- at least one attempt regardless: the flag is advisory.
            if e.fires > 0 and (now - e.fired_t) > SETTLE then
                gone, why = true, "looted"
            elseif not e.mine and (now - e.added) > FLAG_GRACE then
                gone, why = true, "not lootable"
            end
        end
        if gone then
            ltrail("done %s: %s after %d attempt(s)", e.guid, tostring(why), e.fires)
            drop(i)
        else
            local d = safe(function() return player:distance_to(obj) end)
            if type(d) == "number" and (best_d == nil or d < best_d) then
                best_i, best_obj, best_d = i, obj, d
            end
        end
    end
    if not best_i then
        return false
    end

    local e = queue[best_i]
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
        drop(best_i)
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
