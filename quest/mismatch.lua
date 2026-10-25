-- ============================================================================
-- restedXP_questing
-- quest/mismatch.lua - guide / character zone mismatch
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.21.0
-- Folder: restedXP_questing
-- ============================================================================
-- WHY (2.281.0). A dwarf in Coldridge Valley with the HUMAN RestedXP guide
-- loaded (step 3: accept "A Threat Within", Northshire, 2733 yd away) asked
-- AmeisenNav for a path every few seconds - there is none on foot (Ironforge
-- and the Deeprun Tram are in between) - and stood on "cannot reach" for good,
-- the stall recovery skipping one guide goal after another.
--
-- WHAT. The current guide step is a MISMATCH when, together:
--   * every waypoint of the goal is on a different UI map (zone) than the
--     player's (core.game_ui.get_current_map_id),
--   * the nearest one is more than FAR yards away,
--   * the walk to it has been refused ("cannot reach": no path / off the
--     mesh, reported by quest/engine walk_to) within the last UNREACH_RECENT s,
--   * and the bot has not come GAIN yards closer for AFTER seconds.
-- Then the bot stops walking and holds, with the note and one log line:
--   "Guide mismatch: this step is in Elwynn Forest, you are in Dun Morogh -
--    load the RestedXP guide for your character's zone".
-- It lets go by itself when the step changes (another guide loaded, a step
-- skipped by hand), when the player is in the step's zone, or when the step
-- comes within FAR yards. While held, the stall recovery is paused (it would
-- otherwise skip guide goals one after another).
-- ============================================================================

local M = {}

local FAR = 1000
local AFTER = 45
local GAIN = 50
local UNREACH_RECENT = 10

-- UI map ids (Classic / TBC) -> zone names, for the message.
local ZONES = {
    [1411] = "Durotar", [1412] = "Mulgore", [1413] = "The Barrens", [1416] = "Alterac Mountains",
    [1417] = "Arathi Highlands", [1418] = "Badlands", [1419] = "Blasted Lands", [1420] = "Tirisfal Glades",
    [1421] = "Silverpine Forest", [1422] = "Western Plaguelands", [1423] = "Eastern Plaguelands",
    [1424] = "Hillsbrad Foothills", [1425] = "The Hinterlands", [1426] = "Dun Morogh", [1427] = "Searing Gorge",
    [1428] = "Burning Steppes", [1429] = "Elwynn Forest", [1430] = "Deadwind Pass", [1431] = "Duskwood",
    [1432] = "Loch Modan", [1433] = "Redridge Mountains", [1434] = "Stranglethorn Vale",
    [1435] = "Swamp of Sorrows", [1436] = "Westfall", [1437] = "Wetlands", [1438] = "Teldrassil",
    [1439] = "Darkshore", [1440] = "Ashenvale", [1441] = "Thousand Needles", [1442] = "Stonetalon Mountains",
    [1443] = "Desolace", [1444] = "Feralas", [1445] = "Dustwallow Marsh", [1446] = "Tanaris",
    [1447] = "Azshara", [1448] = "Felwood", [1449] = "Un'Goro Crater", [1450] = "Moonglade",
    [1451] = "Silithus", [1452] = "Winterspring", [1453] = "Stormwind City", [1454] = "Orgrimmar",
    [1455] = "Ironforge", [1456] = "Thunder Bluff", [1457] = "Darnassus", [1458] = "Undercity",
    [1941] = "Eversong Woods", [1942] = "Ghostlands", [1943] = "Azuremyst Isle",
    [1944] = "Hellfire Peninsula", [1946] = "Zangarmarsh", [1947] = "The Exodar",
    [1948] = "Shadowmoon Valley", [1949] = "Blade's Edge Mountains", [1950] = "Bloodmyst Isle",
    [1951] = "Nagrand", [1952] = "Terokkar Forest", [1953] = "Netherstorm", [1954] = "Silvermoon City",
    [1955] = "Shattrath City", [1957] = "Isle of Quel'Danas",
}

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local t = safe(izi.now)
        if type(t) == "number" then return t end
    end
    return safe(core.time) or 0
end

function M.zone_name(id)
    id = tonumber(id)
    if not id or id == 0 then return "an unknown zone" end
    return ZONES[id] or ("map " .. tostring(id))
end

local st = { key = nil, best = nil, since = nil, unreach_t = nil, held = false, logged = false, text = nil }

local function reset(key)
    st.key, st.best, st.since, st.held, st.logged, st.text = key, nil, nil, false, false, nil
end

--- quest/engine walk_to: the walk to the goal was refused (no path / off mesh).
function M.note_unreachable()
    st.unreach_t = now()
end

--- Is a mismatch being held right now (the engine's stall recovery waits)?
function M.held()
    return st.held == true
end

local function player_map()
    local id = safe(function() return core.game_ui.get_current_map_id() end)
    id = tonumber(id)
    if id and id > 0 then return id end
    return nil
end

--- `key` identifies the guide goal (step|goal), `wps` its waypoints
--- ({ pos, map_id }), `me` the player's position. Returns held, note text.
function M.check(key, wps, me)
    if key ~= st.key then reset(key) end
    local t = now()
    local pmap = player_map()
    if not pmap or type(wps) ~= "table" or #wps == 0 or type(me) ~= "table" then
        st.held = false
        return false
    end
    local best_d, step_map, same_zone = nil, nil, false
    for i = 1, #wps do
        local w = wps[i]
        local p = w and w.pos
        local m = tonumber(w and w.map_id)
        if m and m > 0 then
            if m == pmap then same_zone = true end
            step_map = step_map or m
        end
        if type(p) == "table" and type(p.x) == "number" and type(me.x) == "number" then
            local dx, dy = p.x - me.x, p.y - me.y
            local d = math.sqrt(dx * dx + dy * dy)
            if not best_d or d < best_d then best_d = d end
        end
    end
    if same_zone or not step_map or not best_d or best_d <= FAR then
        if st.held then
            local log = package.loaded["errorlog"]
            if type(log) == "table" and type(log.trail) == "function" then
                pcall(log.trail, "quest", "guide mismatch cleared - carrying on")
            end
        end
        st.best, st.since, st.held = nil, nil, false
        return false
    end
    if st.held then return true, st.text end
    -- progress toward the step resets the clock
    if not st.best or best_d < st.best - GAIN then
        st.best, st.since = best_d, t
    end
    local refused = st.unreach_t and (t - st.unreach_t) <= UNREACH_RECENT
    if not refused or (t - (st.since or t)) < AFTER then
        return false
    end
    st.held = true
    local here, there = M.zone_name(pmap), M.zone_name(step_map)
    st.text = string.format("Guide mismatch: step is in %s, you are in %s - load the guide for your zone",
        there, here)
    if not st.logged then
        st.logged = true
        local msg = string.format("[restedXP_questing] Guide mismatch: the current RestedXP step is in %s "
            .. "(%.0f yd away, no path on foot) but this character is in %s. Load the RestedXP guide for "
            .. "this character's race / start zone, or move the guide to a step in %s. Questing waits here.",
            there, best_d, here, here)
        pcall(core.log_warning, msg)
        local log = package.loaded["errorlog"]
        if type(log) == "table" and type(log.trail) == "function" then
            pcall(log.trail, "quest", "guide mismatch: step in %s (map %d, %.0f yd), player in %s (map %d) - holding",
                there, step_map, best_d, here, pmap)
        end
    end
    return true, st.text
end

function M._reset() reset(nil); st.unreach_t = nil end

return M
