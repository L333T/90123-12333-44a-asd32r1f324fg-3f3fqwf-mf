-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering: mount up for travel - the shared movement/mount (3.8.0)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.9.1
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- gather/engine.lua's API (tick / suppress / reset / TRAVEL_YARDS) on top of
-- movement/mount.lua, which mounts the way the 1-60 product does: a class
-- mount spell, a mount item in the bags, the game's mount list, or Travel
-- Form; error-message back-offs; 5 tries then 15 s. Core API only.
-- Dismounting at a node / to eat and drink stays with the callers
-- (core.input.dismount).
-- ============================================================================

local MT = require("movement/mount")

local mount = {}

mount.TRAVEL_YARDS = 15

---Hold mounting off for `seconds` (a node is close).
function mount.suppress(seconds) MT.suppress(seconds) end

function mount.reset() MT.reset() end

---@return boolean true while a mount / shift is being cast (the caller
---stands still and gives up the tick).
function mount.tick(player, enabled)
    return MT.step(player, enabled == true)
end

return mount