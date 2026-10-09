-- ============================================================================
-- Master Farmer - Grindbot
-- movement/hazards.lua - learned bad terrain (cliffs, slopes, snag spots)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.257.0
-- ============================================================================
-- WHY (2.235.0)
--   The 23:04 grind session was caught at the same five spots on every lap
--   for an hour - (-5696, -1667), (-5670, -1641), (-5692, -1652),
--   (-5643, -1565) - 20 s each time. Every stuck spot became a 6-yard
--   blacklist zone that expired after 15 minutes, so the next lap walked into
--   it again.
--
-- WHAT
--   Every spot the character gets stuck at (movement/repath area / recovery
--   watch) and every cliff or wall movement/terrain finds becomes a HAZARD:
--     * kept for the whole session (a `keep` zone in movement/zones - never
--       pruned, evicted only after every temporary zone), so Sentinel's
--       obstacle list and find_path_avoid route around it every lap;
--     * hit a second time (a confirmed spot, not a one-off) it is saved to
--       scripts_data/mfg/hazards_<map>.txt and loaded at the next session, so
--       the route avoids it from the start.
--   Only hazards within PUSH_RANGE of the character are kept in the zone list
--   (it holds 24); the rest wait in memory and come back when nearby.
--
-- SWITCHES (Path tab)
--   "Learn Bad Terrain" (on): off -> stuck spots are plain 15-minute zones,
--   nothing is saved or loaded. "Forget Learned Terrain": clears this map's
--   hazards and its file, then unticks itself.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local R = require("movement/rt")
local U = require("movement/util")
local Z = require("movement/zones")

local pt = R.pt
local here_xyz, dist2 = U.here_xyz, U.dist2

local H = {}

local MERGE       = 8.0      -- a new spot this close to a hazard is the same one
local SAVE_HITS   = 2        -- hits before a hazard is written to disk
local R_MIN, R_MAX = 6.0, 12.0
local PUSH_RANGE  = 250.0    -- hazards this close are kept in the zone list
local REFRESH_MOVE = 80.0    -- re-pick the near set after moving this far
local TICK_GAP    = 5.0
local SAVE_GAP    = 15.0
local MAX_HAZARDS = 300
local FOLDER      = "mfb"   -- Ameisen meshes: kept apart from the Sentinel-era mfg hazards

local list = {}              -- { x, y, z, r, hits, why }
local map_key = nil          -- the map the list belongs to
local dirty = false
local last_save = -1e9
local next_tick = 0
local ref_x, ref_y = nil, nil

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "terrain", fmt, ...)
    end
end

local function gui_on(key, default)
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return default end
    local v = gui.is_on(key)
    if type(v) == "boolean" then return v end
    return default
end

local function enabled()
    return gui_on("learn_terrain", true) ~= false
end

local function current_map()
    local ok, id = pcall(function() return core.get_map_id() end)
    if ok and type(id) == "number" then return id end
    return nil
end

local function file_of(map)
    return FOLDER .. "/hazards_" .. tostring(map) .. ".txt"
end

local function load_map(map)
    list = {}
    map_key = map
    dirty = false
    ref_x, ref_y = nil, nil
    if map == nil then return end
    local ok, body = pcall(function() return core.read_data_file(file_of(map)) end)
    if not ok or type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        local x, y, z, r, hits = line:match("^(%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) ([%d%.]+) (%d+)")
        x, y, z, r, hits = tonumber(x), tonumber(y), tonumber(z), tonumber(r), tonumber(hits)
        if x and y and z and r and hits and #list < MAX_HAZARDS then
            list[#list + 1] = { x = x, y = y, z = z, r = r, hits = hits, why = "learned" }
        end
    end
    if #list > 0 then
        trail("loaded %d learned bad-terrain spot(s) for map %s", #list, tostring(map))
    end
end

local function save()
    if map_key == nil then return end
    local out = {}
    for i = 1, #list do
        local h = list[i]
        if h.hits >= SAVE_HITS then
            out[#out + 1] = string.format("%.1f %.1f %.1f %.1f %d", h.x, h.y, h.z, h.r, h.hits)
        end
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    -- write_data_file APPENDS (core.lua stub): empty the file first, or every
    -- save adds every hazard again (and a missing file is never written).
    local ok = pcall(function()
        core.create_data_file(file_of(map_key))
        core.write_data_file(file_of(map_key), table.concat(out, "\n") .. "\n")
    end)
    dirty = false
    last_save = izi.now()
    if not ok then trail("could not write %s", file_of(map_key)) end
end

local function ensure_map()
    local m = current_map()
    if m ~= map_key then
        if dirty then save() end
        load_map(m)
    end
end

--- Put the hazards near (x, y) into the zone list as permanent zones.
local function push_near(x, y)
    for i = 1, #list do
        local h = list[i]
        if dist2(x, y, h.x, h.y) <= PUSH_RANGE then
            Z.blacklist_area(pt(R.P_TMP, h.x, h.y, h.z), h.r, h.why, true)
        end
    end
end

--- A spot the character cannot get past. Learned (kept, maybe saved) when
--- "Learn Bad Terrain" is on; a plain 15-minute zone otherwise.
function H.add(x, y, z, r, why)
    if type(x) ~= "number" or type(y) ~= "number" then return false end
    z = tonumber(z) or 0
    r = tonumber(r) or R_MIN
    if r < R_MIN then r = R_MIN elseif r > R_MAX then r = R_MAX end
    if not enabled() then
        return Z.blacklist_area(pt(R.P_TMP, x, y, z), r, why)
    end
    ensure_map()
    local hit = nil
    for i = 1, #list do
        local h = list[i]
        if dist2(x, y, h.x, h.y) < MERGE then hit = h break end
    end
    if hit then
        hit.hits = hit.hits + 1
        if r > hit.r then hit.r = r end
        if hit.hits == SAVE_HITS then
            dirty = true
            trail("bad terrain at (%.0f, %.0f) hit %d times - saved, routes avoid it from now on", hit.x, hit.y, hit.hits)
        elseif hit.hits > SAVE_HITS then
            dirty = true
        end
    else
        if #list >= MAX_HAZARDS then table.remove(list, 1) end
        hit = { x = x, y = y, z = z, r = r, hits = 1, why = why or "hazard" }
        list[#list + 1] = hit
    end
    return Z.blacklist_area(pt(R.P_TMP, hit.x, hit.y, hit.z), hit.r, why or hit.why, true)
end

--- Per movement pulse.
function H.tick(t)
    if t < next_tick then return end
    next_tick = t + TICK_GAP
    if gui_on("forget_terrain", false) == true then
        ensure_map()
        list = {}
        dirty = true
        save()
        Z.clear_kept()
        trail("learned bad terrain forgotten for map %s", tostring(map_key))
        pcall(function() require("gui").set_on("forget_terrain", false) end)
        return
    end
    if not enabled() then return end
    ensure_map()
    local hx, hy = here_xyz()
    if hx and #list > 0 then
        if not ref_x or dist2(hx, hy, ref_x, ref_y) > REFRESH_MOVE then
            -- Moved on: drop the far ones from the zone list, add the near.
            if ref_x then Z.clear_kept() end
            ref_x, ref_y = hx, hy
        end
        push_near(hx, hy)
    end
    if dirty and (t - last_save) >= SAVE_GAP then save() end
end

function H.count()
    return #list
end

--- Continent change (movement/sentinel_adv -> N.reset_caches): the zone list
--- was cleared; the next tick loads this map's hazards and pushes them.
function H.reset()
    if dirty then save() end
    map_key = nil
    ref_x, ref_y = nil, nil
    next_tick = 0
end

return H
