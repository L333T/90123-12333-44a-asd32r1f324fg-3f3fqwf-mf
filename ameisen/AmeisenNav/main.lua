-- ============================================================================
-- AmeisenNav
-- Main - wiring and the global API
-- ============================================================================
-- Version: 1.6.7
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

local VERSION = "1.6.7"
local BOOT_URL = "http://127.0.0.1:47110/log?src=boot"

--- Startup problems go to the server too: console output may not be visible
--- and file writes are not reliable on every loader build.
local function boot_report(line)
    pcall(core.http_post, BOOT_URL, "AmeisenNav " .. VERSION .. " main: " .. line .. "\n", function() end)
end

local function start()
    for _, name in ipairs({
        "anav/config", "anav/log", "anav/context", "anav/transport",
        "anav/query", "anav/avoid", "anav/pathcheck", "anav/horizon", "anav/follower", "anav/client",
        "anav/follow", "anav/coords", "anav/ui",
    }) do
        package.loaded[name] = nil
    end

    local L      = require("anav/log")
    local Q      = require("anav/query")
    local Client = require("anav/client")
    local UI     = require("anav/ui")
    local X      = require("anav/context")
    local FW     = require("anav/follow")

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
        -- menu values, cached menu status and menu button actions: all of it
        -- reads the game, so none of it may run in the menu render callback
        local oku, erru = xpcall(function() UI.tick(client) end, L.traceback)
        if not oku then L.error("menu tick failed: %s", tostring(erru)) end
        local ok, err = xpcall(function() client:update() end, L.traceback)
        if not ok then L.error("update failed: %s", tostring(err)) end
        local okf, errf = xpcall(function() FW.update(client) end, L.traceback)
        if not okf then L.error("follow update failed: %s", tostring(errf)) end
        L.flush()
    end)

    core.register_on_render_callback(function()
        pcall(UI.render_banner, client)
        pcall(UI.render_world, client)
        pcall(client.render, client)        -- 1.6.0: movement handler after a combat handoff
    end)

    -- Menu elements only. Anything that reads the game belongs in UI.tick.
    core.register_on_render_menu_callback(function()
        local ok, err = xpcall(function() UI.render_menu(VERSION) end, L.traceback)
        if not ok then L.error("menu failed: %s", tostring(err)) end
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
