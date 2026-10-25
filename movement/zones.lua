-- ============================================================================
-- restedXP_questing
-- movement/zones.lua - blacklisted areas
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.6.0
-- ============================================================================
-- Pure bookkeeping, no game calls. An area blacklisted (a destination that
-- failed twice, a death zone - deathzones.lua) is never chosen as a walk
-- target: nav_to refuses it and the grind / quest / path code skips points
-- inside it (movement.is_blocked). Areas expire after ZONE_TTL unless kept.
-- ============================================================================

local R = require("movement/core")

local Z = {}

local ZONE_MIN, ZONE_MAX = 6, 30
local ZONE_DEFAULT = 12
local ZONE_MERGE = 10
local ZONE_TTL = 900
local MAX_ZONES = 40
local PRUNE_EVERY = 5

local zones = {}
local pruned_t = -1e9

function Z.prune(t, force)
    t = t or R.now()
    if not force and (t - pruned_t) < PRUNE_EVERY then return end
    pruned_t = t
    local w = 0
    for i = 1, #zones do
        local z = zones[i]
        if z.keep or (t - z.t) < ZONE_TTL then
            w = w + 1
            zones[w] = z
        end
    end
    for i = #zones, w + 1, -1 do zones[i] = nil end
end

function Z.blocked_xy(x, y)
    for i = 1, #zones do
        local z = zones[i]
        local dx, dy = z.x - x, z.y - y
        if dx * dx + dy * dy <= z.r * z.r then return true end
    end
    return false
end

--- Blacklist an area around `pos` (radius clamped 6..30). `keep`: never expires.
function Z.blacklist_area(pos, radius, why, keep)
    local x, y, z = R.xyz(pos)
    if not x then return false end
    radius = tonumber(radius) or ZONE_DEFAULT
    if radius < ZONE_MIN then radius = ZONE_MIN elseif radius > ZONE_MAX then radius = ZONE_MAX end
    local t = R.now()
    Z.prune(t, true)
    for i = 1, #zones do
        local zn = zones[i]
        if R.dist2(zn.x, zn.y, x, y) < ZONE_MERGE then
            zn.x, zn.y, zn.z, zn.t = x, y, z, t
            if radius > zn.r then zn.r = radius end
            zn.hits = zn.hits + 1
            if keep then zn.keep = true end
            return true
        end
    end
    if #zones >= MAX_ZONES then
        for i = 1, #zones do
            if not zones[i].keep then table.remove(zones, i) break end
        end
    end
    zones[#zones + 1] = { x = x, y = y, z = z, r = radius, t = t, hits = 1, why = why, keep = keep == true }
    R.log(string.format("Blacklist area (%.1f, %.1f, %.1f) r=%.0f%s", x, y, z, radius,
        why and (" - " .. tostring(why)) or ""))
    return true
end

function Z.is_blocked(pos)
    local x, y = R.xyz(pos)
    if not x then return false end
    Z.prune()
    return Z.blocked_xy(x, y)
end

--- Remove the area at (x, y). True when one was removed.
function Z.remove_area(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return false end
    for i = 1, #zones do
        if R.dist2(zones[i].x, zones[i].y, x, y) < ZONE_MERGE then
            table.remove(zones, i)
            return true
        end
    end
    return false
end

function Z.clear_all()
    for i = #zones, 1, -1 do zones[i] = nil end
end

function Z.count() return #zones end

return Z
