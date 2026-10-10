-- ============================================================================
-- Master Farmer - Grindbot
-- deathzones.lua - areas to avoid after dying there 3 times
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.274.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY (2.247.0)
--   death.lua blacklisted the GUID of the mob that killed us. A respawn has a
--   new GUID, and the rest of the camp never had one, so the bot ran back from
--   the graveyard into the same pull and died there again and again.
--
-- WHAT
--   Every death is recorded: where the body fell, the killer's npc id and
--   name, and the map. When the player has died DEATHS_TO_AVOID (3) or more
--   times to the SAME enemy (npc id; an unknown killer matches any) within
--   JOIN_YARDS of each other inside DEATH_WINDOW, that area becomes a DEATH
--   ZONE:
--     * centre = the average of those deaths, radius = their spread +
--       RADIUS_PAD (RADIUS_MIN..RADIUS_MAX yards);
--     * avoided for AVOID_BASE (10 min) + AVOID_EXTRA per further death
--       there (at most AVOID_MAX); dying there again while it is active
--       extends it;
--     * saved to scripts_data/mfb/death_zones.txt with its end time (os.time
--       when the client has it), so a reload or relog keeps avoiding it.
--
--   While a zone is active:
--     * targeting.find_mobs and the quest finders (guide fightable) never pick
--       a mob standing inside it, nor that killer npc within KILLER_PAD yards
--       of it (mobs already attacking us are still fought);
--     * navigation routes around it (movement/zones, radius capped at 30 there)
--       and grind / quest route points inside it are skipped;
--     * the Sylvanas Target Selector is told not to pull while the player is
--       within TS_NEAR yards of it (ts_override_helper set_pull_allowed,
--       ON_CHANGE), and allowed again once away.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local M = {}

M.DEATHS_TO_AVOID = 3
local JOIN_YARDS   = 60      -- deaths this close together are "the same area"
local DEATH_WINDOW = 3600    -- s: deaths older than this no longer count
local RADIUS_PAD   = 25
local RADIUS_MIN   = 30
local RADIUS_MAX   = 80
local AVOID_BASE   = 600     -- s: at least 10 minutes
local AVOID_EXTRA  = 300     -- s per death past the third
local AVOID_MAX    = 3600
local KILLER_PAD   = 20      -- the killer npc is avoided this far past the radius
local TS_NEAR      = 40      -- yards past the radius: no Target Selector pulls
local TICK_GAP     = 1.0
local FOLDER       = "mfb"
local FILE         = FOLDER .. "/death_zones.txt"

local deaths = {}            -- { t, wall, map, x, y, z, npc, name }
local zones = {}             -- { map, x, y, z, r, npc, name, deaths, until_t, until_wall, pushed }
local loaded = false
local next_tick = 0
-- 2.257.0: a ts_override_helper SESSION, not the permanent set_pull_allowed
-- (stub: "legacy, modifies real settings"). destroy() restores the player's
-- own setting: away from the zones, on Stop and on unload (M.release).
local ts_session = nil

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------
local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function now() return safe(izi.now) or 0 end

local function wall()
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then return t end
    return nil
end

local function map_id()
    local id = safe(function() return core.get_map_id() end)
    return type(id) == "number" and id or nil
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "deathzone", fmt, ...)
    end
end

local function d2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function pos_of(u)
    local p = safe(function() return u:get_position() end)
    if type(p) == "table" and type(p.x) == "number" then return p end
    return nil
end

local function mins(s) return math.max(1, math.floor(s / 60 + 0.5)) end

-- ----------------------------------------------------------------------------
-- persistence
-- ----------------------------------------------------------------------------
local function save()
    local out = {}
    local w = wall()
    local t = now()
    for i = 1, #zones do
        local z = zones[i]
        local left = z.until_t - t
        if left > 0 then
            -- end time on the wall clock when there is one, else seconds left
            local ends = w and (w + left) or left
            out[#out + 1] = string.format("%d %.1f %.1f %.1f %.0f %d %d %d %s %s", z.map or 0, z.x, z.y, z.z or 0, z.r,
                z.npc or 0, z.deaths, math.floor(ends), w and "wall" or "left", (tostring(z.name or "?"):gsub("%s", "_")))
        end
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    -- write_data_file APPENDS (core.lua stub): empty the file first, or every
    -- save adds every zone again (and a missing file is never written).
    pcall(function() core.create_data_file(FILE) end)
    pcall(function() core.write_data_file(FILE, table.concat(out, "\n") .. "\n") end)
end

local function load()
    loaded = true
    local body = safe(function() return core.read_data_file(FILE) end)
    if type(body) ~= "string" or body == "" then return end
    local w, t = wall(), now()
    for line in body:gmatch("[^\n]+") do
        local map, x, y, z, r, npc, n, ends, kind, name =
            line:match("^(%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) ([%d%.]+) (%d+) (%d+) (%d+) (%a+) (%S+)")
        map, x, y, z, r, npc, n, ends = tonumber(map), tonumber(x), tonumber(y), tonumber(z), tonumber(r),
            tonumber(npc), tonumber(n), tonumber(ends)
        if x and y and r and ends then
            local left
            if kind == "wall" then left = w and (ends - w) or nil else left = ends end
            if left and left > 0 then
                zones[#zones + 1] = { map = map ~= 0 and map or nil, x = x, y = y, z = z, r = r,
                    npc = npc ~= 0 and npc or nil, name = (name or "?"):gsub("_", " "), deaths = n or 3,
                    until_t = t + left }
                trail("loaded: avoid %s area (%.0f, %.0f) r %.0f for %d more min", tostring(name), x, y, r, mins(left))
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- navigation zone (movement/zones), radius capped at 30 there
-- ----------------------------------------------------------------------------
local function push_nav(z)
    local ok, Z = pcall(require, "movement/zones")
    if not ok or type(Z) ~= "table" or type(Z.blacklist_area) ~= "function" then return end
    local ok_v, vec3 = pcall(require, "common/geometry/vector_3")
    local p = ok_v and vec3 and safe(function() return vec3.new(z.x, z.y, z.z or 0) end) or { x = z.x, y = z.y, z = z.z or 0 }
    pcall(Z.blacklist_area, p, math.min(30, z.r), "died here " .. z.deaths .. "x (" .. tostring(z.name) .. ")", true)
    z.pushed = true
end

local function pull_nav(z)
    if not z.pushed then return end
    local ok, Z = pcall(require, "movement/zones")
    if ok and type(Z) == "table" and type(Z.remove_area) == "function" then
        pcall(Z.remove_area, z.x, z.y)
    end
    z.pushed = false
end

-- ----------------------------------------------------------------------------
-- recording deaths
-- ----------------------------------------------------------------------------
local function zone_at(map, x, y, npc)
    for i = 1, #zones do
        local z = zones[i]
        if (z.map == nil or map == nil or z.map == map) and d2(z.x, z.y, x, y) <= z.r + JOIN_YARDS * 0.5
            and (npc == nil or z.npc == nil or z.npc == npc) then
            return z
        end
    end
    return nil
end

--- A death: `killer` (unit or nil), `pos` (where the body fell, or nil).
function M.record_death(killer, pos)
    if not loaded then load() end
    local me = safe(function() return izi.me() end)
    pos = pos or (me and pos_of(me))
    if type(pos) ~= "table" or type(pos.x) ~= "number" then return end
    local npc, name = nil, nil
    if killer then
        npc = safe(function() return killer:get_npc_id() end)
        if type(npc) ~= "number" or npc <= 0 then npc = nil end
        name = safe(function() return killer:get_name() end)
    end
    local t = now()
    local map = map_id()
    deaths[#deaths + 1] = { t = t, map = map, x = pos.x, y = pos.y, z = pos.z, npc = npc, name = name }
    -- forget old deaths
    local keep = {}
    for i = 1, #deaths do
        if t - deaths[i].t <= DEATH_WINDOW then keep[#keep + 1] = deaths[i] end
    end
    deaths = keep

    -- deaths in this area to this enemy (an unknown killer matches any)
    local same = {}
    for i = 1, #deaths do
        local d = deaths[i]
        if (d.map == nil or map == nil or d.map == map) and d2(d.x, d.y, pos.x, pos.y) <= JOIN_YARDS
            and (npc == nil or d.npc == nil or d.npc == npc) then
            same[#same + 1] = d
            if not name and d.name then name = d.name end
            if not npc and d.npc then npc = d.npc end
        end
    end
    trail("death %d in this area to %s (npc %s) at (%.0f, %.0f) - %d needed to avoid it",
        #same, tostring(name or "unknown"), tostring(npc or "?"), pos.x, pos.y, M.DEATHS_TO_AVOID)
    if #same < M.DEATHS_TO_AVOID then return end

    local cx, cy, cz = 0, 0, 0
    for i = 1, #same do cx, cy, cz = cx + same[i].x, cy + same[i].y, cz + (same[i].z or 0) end
    cx, cy, cz = cx / #same, cy / #same, cz / #same
    local spread = 0
    for i = 1, #same do spread = math.max(spread, d2(cx, cy, same[i].x, same[i].y)) end
    local r = math.max(RADIUS_MIN, math.min(RADIUS_MAX, spread + RADIUS_PAD))
    local dur = math.min(AVOID_MAX, AVOID_BASE + AVOID_EXTRA * (#same - M.DEATHS_TO_AVOID))

    local z = zone_at(map, cx, cy, npc)
    if z then
        z.x, z.y, z.z, z.r = cx, cy, cz, math.max(z.r, r)
        z.deaths = #same
        z.until_t = math.max(z.until_t, t + dur)
        pull_nav(z)
    else
        z = { map = map, x = cx, y = cy, z = cz, r = r, npc = npc, name = name or "unknown enemy",
            deaths = #same, until_t = t + dur }
        zones[#zones + 1] = z
    end
    local msg = string.format("Died %d times to %s here - avoiding the area (%.0f, %.0f), %.0f yd, for %d min.",
        #same, tostring(z.name), cx, cy, z.r, mins(z.until_t - t))
    trail("%s", msg)
    pcall(function() core.log_warning("[Master Farmer - Grindbot] " .. msg) end)
    save()
end

-- ----------------------------------------------------------------------------
-- queries
-- ----------------------------------------------------------------------------
local function active(z, t, map)
    return z.until_t > t and (z.map == nil or map == nil or z.map == map)
end

--- The active zone `pos` lies in, or nil.
function M.zone_at_pos(pos, pad)
    if type(pos) ~= "table" or type(pos.x) ~= "number" or #zones == 0 then return nil end
    local t, map = now(), map_id()
    for i = 1, #zones do
        local z = zones[i]
        if active(z, t, map) and d2(z.x, z.y, pos.x, pos.y) <= z.r + (pad or 0) then return z end
    end
    return nil
end

--- Is `pos` inside an active death zone?
function M.pos_blocked(pos)
    return M.zone_at_pos(pos) ~= nil
end

--- Should `unit` be left alone? Inside a zone, or the zone's killer npc
--- within KILLER_PAD yards past its edge.
function M.unit_blocked(unit)
    if #zones == 0 or not unit then return false end
    local p = pos_of(unit)
    if not p then return false end
    local t, map = now(), map_id()
    local npc = nil
    for i = 1, #zones do
        local z = zones[i]
        if active(z, t, map) then
            local d = d2(z.x, z.y, p.x, p.y)
            if d <= z.r then return true end
            if z.npc and d <= z.r + KILLER_PAD then
                if npc == nil then npc = safe(function() return unit:get_npc_id() end) or false end
                if npc == z.npc then return true end
            end
        end
    end
    return false
end

--- Active zones (for the status line / GUI): { name, x, y, r, minutes_left, deaths }.
function M.list()
    local out, t, map = {}, now(), map_id()
    for i = 1, #zones do
        local z = zones[i]
        if active(z, t, map) then
            out[#out + 1] = { name = z.name, x = z.x, y = z.y, r = z.r, deaths = z.deaths, minutes_left = mins(z.until_t - t) }
        end
    end
    return out
end

--- Forget every zone (and the file).
function M.clear()
    for i = 1, #zones do pull_nav(zones[i]) end
    zones, deaths = {}, {}
    save()
    trail("cleared")
end

-- ----------------------------------------------------------------------------
-- tick: expiry, navigation zones, Target Selector
-- ----------------------------------------------------------------------------
--- Near a zone: a session with pulls off (created once, kept alive with
--- tick()). ts_override_helper:create_session / session:set_pull_allowed /
--- session:tick / session:destroy (stub ts_override_helper.lua).
local function ts_hold()
    if ts_session then
        pcall(ts_session.tick, ts_session)
        return
    end
    local ok, ts = pcall(require, "common/utility/ts_override_helper")
    if not ok or type(ts) ~= "table" or type(ts.create_session) ~= "function" then return end
    local ok_s, sess = pcall(ts.create_session, ts, "Master Farmer - Grindbot death zones")
    if not ok_s or type(sess) ~= "table" then return end
    ts_session = sess
    pcall(sess.set_pull_allowed, sess, false)
    trail("near a death zone: Target Selector pulls off (session)")
end

--- Give the Target Selector back: the session is destroyed and the player's
--- own pull setting applies again. Safe to call any time (Stop, unload).
function M.release()
    if not ts_session then return end
    local sess = ts_session
    ts_session = nil
    pcall(sess.destroy, sess)
    trail("Target Selector session ended - your own pull setting applies")
end

function M.tick()
    local t = now()
    if t < next_tick then return end
    next_tick = t + TICK_GAP
    if not loaded then load() end
    if #zones == 0 then
        M.release()
        return
    end
    local map = map_id()
    local keep, changed = {}, false
    for i = 1, #zones do
        local z = zones[i]
        if z.until_t <= t then
            pull_nav(z)
            changed = true
            trail("avoid area of %s (%.0f, %.0f) expired", tostring(z.name), z.x, z.y)
        else
            keep[#keep + 1] = z
            local here = z.map == nil or map == nil or z.map == map
            if here and not z.pushed then push_nav(z) end
        end
    end
    zones = keep
    if changed then save() end
    -- Target Selector: no auto-pulls near an active zone
    local me = safe(function() return izi.me() end)
    local near = me and M.zone_at_pos(pos_of(me), TS_NEAR) ~= nil or false
    if near then
        ts_hold()
    else
        M.release()
    end
end

return M
