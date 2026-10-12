-- ============================================================================
-- AmeisenNav
-- Main - wiring and the global API
-- ============================================================================
-- Version: 1.4.0
-- Author: BLIZZ
-- Folder: AmeisenNav
-- ============================================================================
-- Consumers:
--
--   local nav = _G.AmeisenNav and _G.AmeisenNav.client
--   if nav then
--       nav:move_to({ x = -9464, y = 62, z = 56 }, function(ok, reason, detail)
--           if not ok then core.log("nav failed: " .. detail.code) end
--       end)
--   end
--
-- Full reference: AmeisenNav/docs/API.md
-- ============================================================================

local VERSION = "2.0.2"   -- Master Farmer release of the AmeisenNav 1.4.0 rework (Desktop Ameisen folder)
local BOOT_URL = "http://127.0.0.1:47110/log?src=boot"

--- Startup problems go to the server too: console output may not be visible
--- and file writes are not reliable on every loader build.
local function boot_report(line)
    pcall(core.http_post, BOOT_URL, "AmeisenNav " .. VERSION .. " main: " .. line .. "\n", function() end)
end

local function start()
    for _, name in ipairs({
        "anav/config", "anav/log", "anav/context", "anav/transport", "anav/query",
        "anav/profile", "anav/avoid", "anav/follower", "anav/client", "anav/follow", "anav/ui", "anav/tune",
    }) do
        package.loaded[name] = nil
    end

    local L      = require("anav/log")
    local Q      = require("anav/query")
    local Client = require("anav/client")
    local UI     = require("anav/ui")
    local X      = require("anav/context")
    local FW     = require("anav/follow")
    local Tune   = require("anav/tune")

    local client = Client.new()

    -- log the raw ids whenever the map changes: which one matches the meshes
    -- has to be confirmed on each continent
    local last_map_key = nil
    local next_map_check = 0
    local function watch_map()
        local now = core.time()
        if now < next_map_check then return end
        next_map_check = now + 1.0
        local inst, ui_map, name, iname = X.map_info()
        local px, py, pz = X.position()
        local key = tostring(inst) .. "|" .. tostring(ui_map) .. "|" .. tostring(px ~= nil)
        if key == last_map_key then return end
        last_map_key = key
        L.info("map: nav id %s (instance_id %s, ui map %s, '%s' / '%s') at %s; %s; filter %s",
            tostring(X.map_id()), tostring(inst), tostring(ui_map), name, iname,
            px and string.format("(%.1f, %.1f, %.1f)", px, py, pz) or "no position",
            X.player_status(), X.filter_state())
    end

    -- Game events (core.register_on_game_event_callback): the callback only
    -- records them; they are handled at the top of the next update tick,
    -- where every other game call is made.
    --   PLAYER_LEAVING_WORLD  loading screen (portal, instance, boat): the
    --                         path belongs to the map being left, and the
    --                         held keys would carry over. End the walk.
    --   PLAYER_DEAD           a corpse cannot walk; without this the stuck
    --                         ladder jumps and repaths until max_stuck_exceeded.
    --   PLAYER_STOPPED_MOVING move forward dropped: the input driver presses
    --                         it again at once instead of after up to 1 s.
    --   PLAYER_REGEN_DISABLED combat handoff, C.combat_mode: "continue" (the
    --   / _ENABLED            default: consumers like Master_Farmer_Bot stop
    --                         AmeisenNav themselves), "pause" (hold the walk
    --                         until combat ends) or "stop" (end it).
    -- The stops report code "cancelled" (detail "loading screen", "player
    -- died", "combat"), which consumers already treat as "not a navigation
    -- failure".
    local F = require("anav/follower")
    local C = require("anav/config")
    local P = require("anav/profile")
    local WATCHED = {
        PLAYER_LEAVING_WORLD = true, PLAYER_DEAD = true, PLAYER_STOPPED_MOVING = true,
        PLAYER_REGEN_DISABLED = true, PLAYER_REGEN_ENABLED = true,
    }
    local pending_events = {}
    if type(core.register_on_game_event_callback) == "function" then
        local okr, errr = pcall(core.register_on_game_event_callback, function(event_name)
            if WATCHED[event_name] then pending_events[#pending_events + 1] = event_name end
        end)
        if not okr then L.warn("game events unavailable: %s", tostring(errr)) end
    end
    local function handle_events()
        if #pending_events == 0 then return end
        local list = pending_events
        pending_events = {}
        for i = 1, #list do
            local ev = list[i]
            if ev == "PLAYER_LEAVING_WORLD" then
                if client:is_busy() then L.info("loading screen: navigation ended") end
                client:stop("loading screen")
            elseif ev == "PLAYER_DEAD" then
                if client:is_busy() then L.info("player died: navigation ended") end
                client:stop("player died")
            elseif ev == "PLAYER_STOPPED_MOVING" then
                F.on_stopped_moving()
            elseif ev == "PLAYER_REGEN_DISABLED" then
                if C.combat_mode == "stop" then
                    if client:is_busy() then L.info("combat: navigation ended") end
                    client:stop("combat")
                elseif C.combat_mode == "pause" then
                    if client:is_busy() then L.info("combat: navigation paused") end
                    client:pause("combat")
                end
            elseif ev == "PLAYER_REGEN_ENABLED" then
                client:resume("combat") -- no-op unless paused for combat
            end
        end
    end

    -- The first frame is the crash window: write and flush a breadcrumb before
    -- anything else runs, so a session that dies here says so in the log file.
    local first_frame = true

    core.register_on_update_callback(function()
        if first_frame then
            first_frame = false
            L.debug("first update frame")
            L.flush(true)
        end
        pcall(watch_map)
        local okp, errp = xpcall(P.update, L.traceback)
        if not okp then L.error("profile update failed: %s", tostring(errp)) end
        local oke, erre = xpcall(handle_events, L.traceback)
        if not oke then L.error("game events failed: %s", tostring(erre)) end
        -- menu values, cached menu status and menu button actions: all of it
        -- reads the game, so none of it may run in the menu render callback
        local oku, erru = xpcall(function() UI.tick(client) end, L.traceback)
        if not oku then L.error("menu tick failed: %s", tostring(erru)) end
        local okt, errt = xpcall(function() Tune.tick(client) end, L.traceback)
        if not okt then L.error("movement menu tick failed: %s", tostring(errt)) end
        local ok, err = xpcall(function() client:update() end, L.traceback)
        if not ok then L.error("update failed: %s", tostring(err)) end
        local okf, errf = xpcall(function() FW.update(client) end, L.traceback)
        if not okf then L.error("follow update failed: %s", tostring(errf)) end
        L.flush()
    end)

    core.register_on_render_callback(function()
        pcall(UI.render_banner, client)
        pcall(UI.render_world, client)
        pcall(Tune.render_world)
    end)

    -- Menu elements only. Anything that reads the game belongs in UI.tick.
    core.register_on_render_menu_callback(function()
        local ok, err = xpcall(function() UI.render_menu(VERSION) end, L.traceback)
        if not ok then L.error("menu failed: %s", tostring(err)) end
        local okt, errt = xpcall(Tune.render_menu, L.traceback)
        if not okt then L.error("movement menu failed: %s", tostring(errt)) end
    end)

    _G.AmeisenNav = {
        VERSION      = VERSION,
        GAME_VERSION = X.GAME_VERSION, -- the running client: "Forever" or "Tbc"
        client       = client,         -- the shared navigation client
        query        = Q,              -- raw navmesh queries (no movement)
        follow       = FW,             -- follow a moving unit: FW.start(mode, name) / FW.stop(client)
    }

    local oke, ev = pcall(core.get_exact_game_version)
    L.info("loaded %s (game %s / %s, map %s) - server %s", VERSION, tostring(X.game_version()),
        tostring(oke and ev), tostring(X.map_id()), require("anav/config").base_url)
    client:health_check()
end

local ok, err = xpcall(start, function(e)
    return tostring(e) .. (debug and debug.traceback and ("\n" .. debug.traceback("", 2)) or "")
end)
if ok then
    boot_report("started")
else
    boot_report("STARTUP FAILED: " .. tostring(err))
    pcall(core.log_error, "[AmeisenNav] startup failed: " .. tostring(err))
end
