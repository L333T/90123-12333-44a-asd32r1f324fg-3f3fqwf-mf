-- ============================================================================
-- Master Farmer - Grindbot
-- callbacks.lua - IZI callbacks: combat finished, spell cancelled
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.276.0
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
-- REGISTRATION
-- ----------------------------------------------------------------------------
_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}
local NS = _G.MasterFarmer_Grindbot

local function dispatch(name)
    return function(ev)
        local live = NS.izi_cb_handlers
        local h = type(live) == "table" and live[name] or nil
        if not h then return end
        local ok, err = pcall(h, ev)
        if not ok then
            pcall(core.log_error, "[Master Farmer - Grindbot] izi callback " .. name .. ": " .. tostring(err))
        end
    end
end

--- Register once per session; later loads only swap the handler table.
function cb.install()
    NS.izi_cb_handlers = handlers
    if NS.izi_cb_unsub then return false end
    if not ok_izi or type(izi) ~= "table"
        or type(izi.on_combat_finish) ~= "function" or type(izi.on_spell_cancel) ~= "function" then
        return false
    end
    local unsub = {}
    local ok1, u1 = pcall(izi.on_combat_finish, dispatch("combat_finish"))
    if ok1 and type(u1) == "function" then unsub[#unsub + 1] = u1 end
    local ok2, u2 = pcall(izi.on_spell_cancel, dispatch("spell_cancel"))
    if ok2 and type(u2) == "function" then unsub[#unsub + 1] = u2 end
    NS.izi_cb_unsub = unsub
    return true
end

--- Unsubscribe (main.lua on_unload).
function cb.uninstall()
    local list = NS.izi_cb_unsub
    NS.izi_cb_unsub = nil
    if type(list) ~= "table" then return end
    for i = 1, #list do pcall(list[i]) end
end

return cb
