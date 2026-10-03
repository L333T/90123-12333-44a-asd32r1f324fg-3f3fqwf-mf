-- ============================================================================
-- Master Farmer - Grindbot
-- Header — load gate
-- ============================================================================
-- Purpose: TBC + IZI gate. Not class-locked. Start is gated by rotation registry.
-- Authors: BLIZZ - Anthonyk
-- Version: 2.212.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

local identity = require("version")

local plugin = {}
plugin["name"] = identity.name
plugin["short_tag"] = identity.short_tag
plugin["version"] = identity.version
plugin["author"] = identity.authors
plugin["load"] = true

-- The header runs before a player exists and is not asked again, so this
-- gate does not require one. Class is not a gate. Both version calls are
-- pcalled, then the decision is posted to the local nav boot log.
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
call(core.log, "[Master Farmer - Grindbot] " .. line)

if not load then
    plugin["load"] = false
    return plugin
end

local izi_ok, izi = pcall(require, "common/izi_sdk")
if (not izi_ok) or type(izi) ~= "table" then
    core.log_error("[Master Farmer - Grindbot] common/izi_sdk is unavailable - plugin not loaded.")
    plugin["load"] = false
    return plugin
end

local required_izi = {
    "on_update",
    "spell",
    "item",
    "enemies",
    "me",
    "now",
}
local missing = {}
for i = 1, #required_izi do
    local field = required_izi[i]
    if type(izi[field]) ~= "function" then
        missing[#missing + 1] = field
    end
end
if #missing > 0 then
    core.log_error("[Master Farmer - Grindbot] izi_sdk missing: " .. table.concat(missing, ", "))
    plugin["load"] = false
    return plugin
end

_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}
local NS = _G.MasterFarmer_Grindbot
NS.meta = {
    name = identity.name,
    version = identity.version,
    author = identity.authors,
    description = identity.description,
}
NS._sessions = NS._sessions or {}
NS._sessions[identity.folder] = (NS._sessions[identity.folder] or 0) + 1

return plugin
