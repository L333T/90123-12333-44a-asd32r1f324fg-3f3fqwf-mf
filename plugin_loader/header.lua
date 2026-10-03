-- ============================================================================
-- Master Farmer - Grindbot  ::  HTTP PLUGIN LOADER
-- header.lua - load gate
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Loader version: 1.2.3   (this is the LOADER's version, not the bot's - the
--                          bot's version is whatever the manifest reports)
-- ============================================================================
-- DO NOT EDIT THIS FOLDER TO SHIP A BOT CHANGE.
-- Merging to GitHub main is what the game loads. This folder is only the
-- gate and the downloader. Touch it when the download mechanism itself
-- changes, not when the bot does.
--
-- It loads on TBC Classic ("Tbc") and WoW Forever ("Forever") for every
-- class. There is no class list here on purpose: a new class must not
-- require a new loader.
--
-- This is a standalone plugin whose only job is to download the real plugin.
-- Install this folder on its own; do not install it alongside a local copy of
-- the bot, or two update callbacks will drive the same character.
--
-- WHY THE BOOT POST DOES NOT DECIDE THE LOAD
--   Sylvanas reads `plugin.load` from the value this chunk RETURNS, so the
--   decision is made here, from the two version calls. The POST to the local
--   nav boot log is fire-and-forget: its callback cannot change plugin.load.
--   The download itself starts from main.lua.
--
-- WHY THERE IS NO INLINED COPY OF THE BOT'S IDENTITY
--   An earlier version of this loader hardcoded the bot's `folder` string so it
--   could bump the shared session counter that the bot's own main.lua uses for
--   its is_stale() guard. That string then drifted from the downloaded
--   version.lua, and a drifted key breaks the guard SILENTLY: the bot watches a
--   counter nobody increments, so on reload the previous load's callbacks never
--   go quiet and stack up instead.
--
--   So this loader keeps its own counter under its own key, and main.lua bumps
--   the bot's real key AFTER version.lua has been downloaded and can be read.
--   There is nothing left to keep in sync by hand.
-- ============================================================================

local LOADER_KEY     = "MFG_HTTP_LOADER"
local LOADER_VERSION = "1.2.3"   -- 1.2.3: quiet console, no HTTP / URL detail unless VERBOSE

local plugin = {}
plugin["name"]      = "Master Farmer - Grindbot"
plugin["short_tag"] = "MFG"
plugin["version"]   = LOADER_VERSION
plugin["author"]    = "BLIZZ - Anthonyk"
plugin["load"]      = true

local function refuse(msg)
    if msg then core.log_error("[Master Farmer] " .. msg) end
    plugin["load"] = false
    return plugin
end

-- Same shape as the AmeisenNav gate. pcall both version calls, decide load
-- from the answers, and post the line. The header runs before a player
-- exists and is not asked again, so a player check here meant the plugin
-- never loaded. Class is not a gate.
local SUPPORTED = { Forever = true, Tbc = true }
local BOOT_URL = "http://127.0.0.1:47110/log?src=boot"

local function call(fn, ...)
    if type(fn) ~= "function" then return false, "missing" end
    return pcall(fn, ...)
end

local okv, version = call(core.get_game_version)
local oke, exact = call(core.get_exact_game_version)
local load = (okv and SUPPORTED[version] == true) or (oke and exact == "wow_forever_beta_us")

local line = string.format("Master Farmer %s header: load=%s game_version=%s exact=%s",
    plugin["version"], tostring(load), tostring(version), tostring(oke and exact or exact))
call(core.http_post, BOOT_URL, line .. "\n", function() end)
if not load then
    call(core.log, "[Master Farmer] not loaded on this game version (" .. tostring(version) .. ")")
end

if not load then
    plugin["load"] = false
    return plugin
end

-- Without HTTP this plugin can do literally nothing, so refuse here rather than
-- loading and then sitting idle with no explanation.
if type(core.http_get) ~= "function" then
    return refuse("this build cannot load the plugin (no download support).")
end

local izi_ok, izi = pcall(require, "common/izi_sdk")
if (not izi_ok) or type(izi) ~= "table" then
    return refuse("common/izi_sdk is unavailable - plugin not loaded.")
end

local required_izi = { "on_update", "spell", "item", "enemies", "me", "now" }
local missing = {}
for i = 1, #required_izi do
    if type(izi[required_izi[i]]) ~= "function" then
        missing[#missing + 1] = required_izi[i]
    end
end
if #missing > 0 then
    return refuse("izi_sdk missing: " .. table.concat(missing, ", "))
end

_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}
local NS = _G.MasterFarmer_Grindbot

-- The loader's OWN session generation. Bumping it is what makes the previous
-- load's update callback go quiet. This key is private to the loader and is
-- deliberately NOT the bot's folder key.
NS._sessions = NS._sessions or {}
NS._sessions[LOADER_KEY] = (NS._sessions[LOADER_KEY] or 0) + 1

NS._loader = {
    key     = LOADER_KEY,
    version = LOADER_VERSION,
}

return plugin
