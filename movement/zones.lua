-- ============================================================================
-- Master Farmer - Grindbot
-- movement/zones.lua - blacklist zones
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.275.0
-- ============================================================================
-- Areas movement refuses to path into, pruned in place on a TTL. Nothing here
-- issues a command, so every other module may require it freely.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")

local ZONE_RADIUS      = K.ZONE_RADIUS
local ZONE_MERGE       = K.ZONE_MERGE
local ZONE_TTL         = K.ZONE_TTL
local ZONE_PRUNE_EVERY = K.ZONE_PRUNE_EVERY
local MAX_ZONES        = K.MAX_ZONES

local xyz, dist2, log = U.xyz, U.dist2, U.log

local Z = {}

-- ----------------------------------------------------------------------------
-- SENTINEL AVOIDANCE ZONES (2.59.0)
-- ----------------------------------------------------------------------------
-- Every blacklisted area is mirrored into Sentinel's ObstacleService so its
-- paths go AROUND it - our own list only refuses destinations. Read straight
-- from the global (requiring movement/sentinel here would close a cycle).
-- When our list shrinks, Sentinel's is cleared and re-filled from it.
local sn_count = 0

-- MASTER FARMER BOT (Ameisen): AmeisenNav keeps no obstacle list, so there is
-- nothing to mirror into - the zones reach Ameisen's routes through
-- movement/sentinel.lua avoid_plan (find_path + a detour beside the zone).
local function obstacle()
    return nil
end

local function sn_add(z)
    local ob = obstacle()
    if not ob or type(ob.add_zone) ~= "function" then return end
    local ok_v, vec3 = pcall(require, "common/geometry/vector_3")
    local pos = (ok_v and type(vec3) == "table") and vec3.new(z.x, z.y, z.z) or { x = z.x, y = z.y, z = z.z }
    if pcall(ob.add_zone, ob, pos, z.r) then
        sn_count = sn_count + 1
    end
end

local function sn_resync(zones)
    local ob = obstacle()
    if not ob or type(ob.clear) ~= "function" then return end
    pcall(ob.clear, ob)
    sn_count = 0
    for i = 1, #zones do
        sn_add(zones[i])
    end
end

function Z.prune(t, force)
    if not force and (t - R.zones_pruned_t) < ZONE_PRUNE_EVERY then return end
    R.zones_pruned_t = t
    local zones = R.zones
    local n, w = #zones, 0
    for i = 1, n do
        local z = zones[i]
        -- A learned hazard (movement/hazards, 2.235.0) never expires here.
        if z.keep or (t - z.t) < ZONE_TTL then
            w = w + 1
            zones[w] = z
        end
    end
    for i = w + 1, n do zones[i] = nil end
    if w < n and sn_count > 0 then
        sn_resync(zones)
    end
end

--- Is (x, y) inside any blacklist zone? Squared distances, no allocation.
function Z.blocked_xy(x, y)
    local zones = R.zones
    for i = 1, #zones do
        local z = zones[i]
        local dx, dy = z.x - x, z.y - y
        if dx * dx + dy * dy <= z.r * z.r then return true end
    end
    return false
end

function Z.blacklist_area(pos, radius, why, keep)
    local x, y, z = xyz(pos)
    if not x then return false end
    radius = tonumber(radius) or ZONE_RADIUS
    if radius < 6 then radius = 6 elseif radius > 30 then radius = 30 end
    local t = izi.now()
    Z.prune(t, true)
    local zones = R.zones
    for i = 1, #zones do
        local zn = zones[i]
        if dist2(zn.x, zn.y, x, y) < ZONE_MERGE then
            zn.x, zn.y, zn.z, zn.t = x, y, z, t
            if radius > zn.r then zn.r = radius end
            zn.hits = zn.hits + 1
            if keep then zn.keep = true end
            return true
        end
    end
    local evicted = false
    if #zones >= MAX_ZONES then
        -- The oldest TEMPORARY zone goes first; a learned hazard only when
        -- every zone is one (2.235.0).
        local victim = 1
        for i = 1, #zones do
            if not zones[i].keep then victim = i break end
        end
        table.remove(zones, victim)
        evicted = true
    end
    zones[#zones + 1] = { x = x, y = y, z = z, r = radius, t = t, hits = 1, why = why, keep = keep == true }
    if evicted then
        sn_resync(zones)
    else
        sn_add(zones[#zones])
    end
    log(string.format("Blacklist area (%.1f, %.1f, %.1f) r=%.0f%s", x, y, z, radius,
        why and (" - " .. tostring(why)) or ""))
    return true
end

function Z.is_blocked(pos)
    local x, y = xyz(pos)
    if not x then return false end
    Z.prune(izi.now())
    return Z.blocked_xy(x, y)
end

-- ----------------------------------------------------------------------------
-- DANGER MAP (2.95.0)
-- ----------------------------------------------------------------------------
-- Mobs too high to fight, from targeting.scan_enemies: replaced on every scan,
-- never logged or sent to Sentinel, and they only steer - a destination near
-- one is still allowed, a hop through its aggro radius is not.
function Z.set_danger(list)
    R.danger = type(list) == "table" and list or {}
end

--- Is (x, y) inside a dangerous mob's radius?
function Z.dangerous_xy(x, y)
    local list = R.danger
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        local d = list[i]
        local dx, dy = d.x - x, d.y - y
        if dx * dx + dy * dy <= d.r * d.r then return true end
    end
    return false
end

-- ADVANCED-API HOOKS (2.219.0, movement/sentinel_adv.lua) -------------------
--- How many zones this plugin has pushed to Sentinel's obstacle list.
function Z.sentinel_count()
    return sn_count
end

--- Push every zone to Sentinel again (its list was lost - a server restart).
function Z.resync_sentinel()
    sn_resync(R.zones)
end

--- Forget every blacklist zone, ours and the mirror (a continent change: the
--- zones are x / y only and would block the same coordinates elsewhere).
function Z.clear_all()
    local zones = R.zones
    for i = #zones, 1, -1 do zones[i] = nil end
    sn_resync(zones)
end

--- Drop every learned-hazard zone (movement/hazards "forget", 2.235.0).
function Z.clear_kept()
    local zones = R.zones
    local w = 0
    for i = 1, #zones do
        if not zones[i].keep then w = w + 1 zones[w] = zones[i] end
    end
    for i = #zones, w + 1, -1 do zones[i] = nil end
    sn_resync(zones)
end

--- 2.247.0: drop the zone at (x, y) (deathzones.lua, when its time is up).
function Z.remove_area(x, y)
    local zones = R.zones
    local w, gone = 0, false
    for i = 1, #zones do
        local zn = zones[i]
        if not gone and dist2(zn.x, zn.y, x, y) < ZONE_MERGE then
            gone = true
        else
            w = w + 1
            zones[w] = zn
        end
    end
    for i = #zones, w + 1, -1 do zones[i] = nil end
    if gone then sn_resync(zones) end
    return gone
end

function Z.count()
    Z.prune(izi.now(), true)
    return #R.zones
end

return Z
