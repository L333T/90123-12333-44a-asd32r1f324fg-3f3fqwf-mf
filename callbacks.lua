-- ============================================================================
-- Master Farmer - Grindbot
-- callbacks.lua - combat finished, spell cancelled (core API polling, 2.315.0)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.316.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY (2.271.0)
--   The end of a fight and a cancelled cast were only noticed by polling:
--   the attacker count (cached ATTACK_TTL), loot's combat flag (read on the
--   next loot tick), the RestedXP snapshot (0.25 s window), the spell queue's
--   stuck check (1 s) and the movement cast lock (re-checked every 0.25 s).
--
-- WHAT (IZI Callbacks: izi.on_combat_finish, izi.on_spell_cancel)
--   on_combat_finish, for the player only:
--     * targeting's attacker cache is dropped - "nobody attacking" is true
--       this tick, so looting and the rest start at once;
--     * loot is told the exact moment the fight ended (its REST_DELAY hold);
--     * the RestedXP snapshot is dropped - a kill's progress is read now.
--   on_spell_cancel, for the player's own casts only:
--     * the spell is dropped from the spell queue's bookkeeping (castq) and
--       from the rotation's back-off (smart) - it can be cast again at once,
--       and the global cooldown it never used is given back;
--     * the movement cast lock is released, so the character is not held
--       still for a cast that is gone.
--
-- REGISTERING ONCE
--   Same rule as events.lua: the plugin hot-reloads by clearing
--   package.loaded, so the guard and the handler table live on
--   _G.MasterFarmer_Grindbot, and the callback reads the CURRENT handlers.
--   Every izi.on_* returns an unsubscribe function: kept, and called by
--   main.lua's on_unload (callbacks.uninstall).
-- ============================================================================

local cb = {}

local ok_izi, izi = pcall(require, "common/izi_sdk")

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "event", fmt, ...)
    end
end

local function mod(name)
    local m = package.loaded[name]
    if type(m) == "table" then return m end
    local ok, r = pcall(require, name)
    if ok and type(r) == "table" then return r end
    return nil
end

--- Is `unit` the local player? By GUID - comparing game objects can throw.
local function is_me(unit)
    if not ok_izi or type(izi) ~= "table" or unit == nil then return false end
    local me = safe(izi.me)
    if not me then return false end
    local a = safe(function() return me:get_guid() end)
    local b = safe(function() return unit:get_guid() end)
    return a ~= nil and a == b
end

-- ----------------------------------------------------------------------------
-- HANDLERS
-- ----------------------------------------------------------------------------
local handlers = {}

function handlers.combat_finish(ev)
    if type(ev) ~= "table" or not is_me(ev.unit) then return end
    local tg = mod("targeting")
    if tg and type(tg.forget_attackers) == "function" then pcall(tg.forget_attackers) end
    local lt = mod("loot")
    if lt and type(lt.note_combat_end) == "function" then pcall(lt.note_combat_end) end
    local guide = package.loaded["quest/guide"]
    if type(guide) == "table" and type(guide.invalidate) == "function" then pcall(guide.invalidate) end
    trail("combat finished")
end

function handlers.spell_cancel(ev)
    if type(ev) ~= "table" or not is_me(ev.caster) then return end
    local id = tonumber(ev.spell_id)
    if not id or id <= 0 then return end
    local cq = mod("castq")
    if cq and type(cq.cancelled) == "function" then pcall(cq.cancelled, id) end
    local sm = package.loaded["smart"]
    if type(sm) == "table" and type(sm.cast_cancelled) == "function" then pcall(sm.cast_cancelled, id) end
    local mv = package.loaded["movement"]
    if type(mv) == "table" and type(mv.cast_cancelled) == "function" then pcall(mv.cast_cancelled) end
    trail("cast cancelled: spell %d", id)
end

cb.handlers = handlers

-- ----------------------------------------------------------------------------
-- POLLING (2.315.0) - the core API, the player only, no IZI callbacks
-- ----------------------------------------------------------------------------
-- izi.on_combat_finish / izi.on_spell_cancel are fired by izi.on_update, IZI's
-- per-frame engine, which is no longer called (main.lua). The same two edges
-- are read here once per frame from the local player:
--   combat finished  is_in_combat() true -> false
--   cast cancelled   the cast / channel being watched ends more than
--                    CANCEL_EARLY ms before its own end time (core.game_time)
_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}
local NS = _G.MasterFarmer_Grindbot

local CANCEL_EARLY = 200
local watch = { in_combat = false, id = nil, ends = nil }

local function local_player()
    local ok, p = pcall(function() return core.object_manager.get_local_player() end)
    if ok and p and safe(function() return p:is_valid() end) == true then return p end
    return nil
end

local function call(h, ev)
    local live = NS.izi_cb_handlers
    local f = type(live) == "table" and live[h] or nil
    if not f then return end
    local ok, err = pcall(f, ev)
    if not ok then
        pcall(core.log_error, "[Master Farmer - Grindbot] callback " .. h .. ": " .. tostring(err))
    end
end

--- Once per frame (main.lua on_update).
function cb.tick()
    local me = local_player()
    if not me then
        watch.id, watch.ends = nil, nil
        return
    end
    local in_c = safe(function() return me:is_in_combat() end) == true
    if watch.in_combat and not in_c then call("combat_finish", { unit = me }) end
    watch.in_combat = in_c

    local id, ends = nil, nil
    if safe(function() return me:is_casting_spell() end) == true then
        id = tonumber(safe(function() return me:get_active_spell_id() end))
        ends = tonumber(safe(function() return me:get_active_spell_cast_end_time() end))
    elseif safe(function() return me:is_channelling_spell() end) == true then
        id = tonumber(safe(function() return me:get_active_channel_spell_id() end))
        ends = tonumber(safe(function() return me:get_active_channel_cast_end_time() end))
    end
    if id and id <= 0 then id = nil end
    if watch.id and watch.id ~= id then
        local now = tonumber(safe(core.game_time))
        if now and watch.ends and now < watch.ends - CANCEL_EARLY then
            call("spell_cancel", { caster = me, spell_id = watch.id })
        end
    end
    watch.id, watch.ends = id, id and ends or nil
end

--- Swap in this load's handlers; drop any IZI subscriptions an earlier
--- version registered (2.271.0 - 2.314.0).
function cb.install()
    NS.izi_cb_handlers = handlers
    local old = NS.izi_cb_unsub
    NS.izi_cb_unsub = nil
    if type(old) == "table" then
        for i = 1, #old do pcall(old[i]) end
    end
    return true
end

--- main.lua on_unload: nothing is registered any more; kept for the caller.
function cb.uninstall()
    local list = NS.izi_cb_unsub
    NS.izi_cb_unsub = nil
    if type(list) ~= "table" then return end
    for i = 1, #list do pcall(list[i]) end
end

return cb
