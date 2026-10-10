-- ============================================================================
-- AmeisenNav
-- Header - Load Gate
-- ============================================================================
-- Version: 1.6.5
-- Author: BLIZZ
-- Folder: AmeisenNav
-- Shared navmesh navigation for every Sylvanas plugin, backed by the local
-- AmeisenNavigation server (scripts\Ameisen\Start-Ameisen.bat, http://127.0.0.1:47110).
-- Replaces SentinelNavClient. Consumers use _G.AmeisenNav.client.
-- ============================================================================
-- GAME VERSION  Loads on every client. core.get_game_version() is logged only.
--               Runtime quirks (no get_local_player, simple_movement refusing a
--               path, look_at not turning, race_id 0) are probed in anav/.
--               The nav server must have the mmaps for the map you walk on.
-- NO PLAYER GATE  The loader evaluates headers before the player object
--               exists and does not load the plugin later, so requiring a
--               player here meant it never loaded. Everything in anav/
--               handles "no player yet" at runtime.
-- Each load decision is also reported to the nav server (POST /log?src=boot).
-- ============================================================================

local plugin = {}
plugin["name"]      = "AmeisenNav"
plugin["short_tag"] = "ANAV"
plugin["version"]   = "1.6.5"
plugin["author"]    = "BLIZZ"
plugin["load"]      = true

local BOOT_URL = "http://127.0.0.1:47110/log?src=boot"

local function call(fn, ...)
    if type(fn) ~= "function" then return false, "missing" end
    return pcall(fn, ...)
end

local _, version = call(core.get_game_version)
local oke, exact = call(core.get_exact_game_version)

local line = string.format("AmeisenNav %s header: load=true game_version=%s exact=%s",
    plugin["version"], tostring(version), tostring(oke and exact or exact))
call(core.http_post, BOOT_URL, line .. "\n", function() end)

return plugin
