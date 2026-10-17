-- ============================================================================
-- Master Farmer - Grindbot
-- gather/detour.lua - leave a recorded path for a herb / ore node, gather it
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.9.1
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Used by grind/engine while a recorded path runs (the Path tab's loaded
-- grind / travel profile). Out of combat, every LOOK_S it asks the node ESP
-- cache (gather/esp) for the nearest node this character can gather within
-- the "Node Detour Range". Found:
--   GO      the route walk is stopped and movement.nav_to walks to the node -
--           the navigation system (MasterArthasNav exact server path, mounting
--           for 30 yd+ walks); re-sent only when the walk stopped or every 3 s.
--   GATHER  within USE_RANGE: dismount, halt, use the node (core.input.
--           use_object - the game casts Herb Gathering or Mining by the node's
--           kind), wait out the cast, loot every slot of the loot window.
--   DONE    the node gone / used -> marked looted; the caller walks back onto
--           the recorded path (grind/engine rejoin: nearest point of the line,
--           or its nearest waypoint when farther than 40 yd) and the path runs on.
-- Give-ups (blacklisted in gather/scan for the session): MAX_S without
-- gathering it, USES tries at the node, a navigation failure. A fight that
-- starts meanwhile is the grind engine's; the detour carries on after it.
-- Core API only.
-- ============================================================================

local M = {}

local LOOK_S = 0.5
local USE_RANGE = 4.5
local GONE_RANGE = 30
local MAX_S = 90
local USES = 5
local USE_GAP = 1.2
local LOOT_GAP = 0.3
local RESEND_S = 3

M.ID = { on = "mfg_path_gather", range = "mfg_path_gather_yards", herb = "mfg_path_gather_herb", ore = "mfg_path_gather_ore" }

local st = { node = nil, since = 0, look_t = -1e9, use_t = -1e9, loot_t = -1e9, send_t = -1e9, uses = 0 }
M.stats = { started = 0, gathered = 0, given_up = 0 }

local function now()
    local ok, t = pcall(core.time)
    return (ok and type(t) == "number") and t or 0
end

local function call(o, method, ...)
    local fn = o and o[method]
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, o, ...)
    if ok then return v end
    return nil
end

local function req(name)
    local ok, m = pcall(require, name)
    return ok and type(m) == "table" and m or nil
end

local function note(text)
    local state = req("state")
    if state and type(state.set_note) == "function" then pcall(state.set_note, "Grind", text) end
end

local function trail(fmt, ...)
    pcall(core.log, "[Master Farmer - Grindbot] Path gather: " .. string.format(fmt, ...))
end

function M.active() return st.node ~= nil end
function M.current() return st.node end

function M.reset()
    st.node, st.uses = nil, 0
    st.look_t, st.use_t, st.loot_t, st.send_t = -1e9, -1e9, -1e9, -1e9
end

local function finish(gathered, why)
    local n = st.node
    local scan = req("gather/scan")
    if n and scan then
        if gathered then scan.mark_looted(n.guid) else scan.blacklist(n.guid) end
    end
    if gathered then M.stats.gathered = M.stats.gathered + 1 else M.stats.given_up = M.stats.given_up + 1 end
    if n then trail("%s %s (%s)", gathered and "gathered" or "gave up on", tostring(n.name), tostring(why)) end
    M.reset()
    pcall(function() core.input.close_loot() end)
    return true                        -- this tick was the detour's; the caller rejoins next
end

local function loot_window()
    local ok, n = pcall(core.game_ui.get_loot_item_count)
    n = ok and tonumber(n) or 0
    if n <= 0 then return false end
    local t = now()
    if (t - st.loot_t) < LOOT_GAP then return true end
    st.loot_t = t
    for i = n - 1, 0, -1 do pcall(core.input.loot_item, i) end
    return true
end

local function enabled(gui)
    return gui and gui.is_on(M.ID.on) == true
end

--- The detour's tick. True while it owns the tick (walking to / gathering a
--- node, or the tick it finished in); false = nothing to do, walk the path.
--- `opts.in_combat` - the caller's combat state (no new detour in combat).
function M.tick(player, opts)
    if not player then return false end
    local gui = req("gui")
    local movement = req("movement")
    local esp = req("gather/esp")
    if not gui or not movement or not esp then return false end
    local t = now()
    local in_combat = (opts and opts.in_combat) or call(player, "is_in_combat") == true

    if not st.node then
        if not enabled(gui) or in_combat then return false end
        if (t - st.look_t) < LOOK_S then return false end
        st.look_t = t
        esp.update(player)
        local want = { herb = gui.is_on(M.ID.herb) ~= false, ore = gui.is_on(M.ID.ore) ~= false }
        local me = call(player, "get_position")
        local range = tonumber(gui.slider(M.ID.range, 50)) or 50
        local e = me and esp.nearest(me, range, want)
        if not e then return false end
        st.node = { guid = e.guid, name = e.name, kind = e.kind, x = e.x, y = e.y, z = e.z, obj = e.obj }
        st.since, st.uses, st.send_t = t, 0, -1e9
        M.stats.started = M.stats.started + 1
        trail("%s %s at %.0f yd - leaving the path", e.kind == "herb" and "herb" or "ore", e.name, e.dist or -1)
        pcall(movement.nav_stop)
        if type(movement.clear_fail) == "function" then pcall(movement.clear_fail) end   -- an old route failure is not this walk's
    end

    local n = st.node
    if not enabled(gui) then M.reset() return false end
    if (t - st.since) > MAX_S then return finish(false, "timer") end
    local me = call(player, "get_position")
    if type(me) ~= "table" then return true end
    local d = math.sqrt((n.x - me.x) ^ 2 + (n.y - me.y) ^ 2 + (n.z - (me.z or 0)) ^ 2)

    -- fresh cache: is the node still there?
    esp.update(player)
    local e = n.guid and esp.get(n.guid) or nil
    if e then n.obj = e.obj end
    if d < GONE_RANGE and esp.age() < 1 and not e then
        if loot_window() then note("Looting " .. n.name) return true end
        return finish(st.uses > 0, st.uses > 0 and "used" or "gone")
    end

    if d > USE_RANGE then
        if in_combat then return true end
        if type(movement.last_fail_offmesh) == "function" and movement.last_fail_offmesh() then
            return finish(false, "no path")
        end
        note(string.format("To %s %s  %.0f yd", n.kind == "herb" and "herb" or "ore", n.name, d))
        if not movement.is_moving() or (t - st.send_t) > RESEND_S then
            st.send_t = t
            movement.nav_to({ x = n.x, y = n.y, z = n.z }, true)
        end
        return true
    end

    -- at the node
    if call(player, "is_mounted") == true then
        pcall(core.input.dismount)
        return true
    end
    pcall(movement.halt)
    if type(movement.pause_for_loot) == "function" then pcall(movement.pause_for_loot, 2) end
    if loot_window() then note("Looting " .. n.name) return true end
    if e and not e.gatherable and st.uses > 0 then return finish(true, "used") end
    if call(player, "is_moving") == true then return true end
    if call(player, "is_casting_spell") == true or call(player, "is_channelling_spell") == true then
        note((n.kind == "herb" and "Herbing " or "Mining ") .. n.name)
        return true
    end
    if (t - st.use_t) < USE_GAP then return true end
    if st.uses >= USES then return finish(false, USES .. " tries") end
    if not n.obj or call(n.obj, "is_valid") ~= true then return finish(st.uses > 0, "gone") end
    st.use_t = t
    st.uses = st.uses + 1
    pcall(core.input.use_object, n.obj)
    note((n.kind == "herb" and "Herbing " or "Mining ") .. n.name)
    return true
end

return M
