-- ============================================================================
-- Master Farmer - Grindbot
-- Recorded Alliance roads to inns and flight masters
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.196.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- data/ek_alliance_routes.lua holds the PathTool roads. A destination that
-- sits on an inn or flight-path end, and a player already on that road or
-- whose straight line crosses it, is steered to the next recorded point.
-- The caller retargets with nudge / nav_to. This module never stops movement.
-- ============================================================================

local M = {}

local ROUTES = require("data/ek_alliance_routes")

local END_REACH = 45          -- destination is this inn / flight master
local ON_ROUTE = 50           -- player is already on the road
local CROSS = 35              -- the line to the destination meets the road
local SKIP_TAIL = 30          -- the points sitting on the destination are not a crossing
local NEAR_DEST = 18          -- last yards: the real destination, not a road point
local HOP_AHEAD = 18          -- next road point issued at least this far ahead

local END2 = END_REACH * END_REACH
local ON2 = ON_ROUTE * ON_ROUTE
local CROSS2 = CROSS * CROSS
local SKIP2 = SKIP_TAIL * SKIP_TAIL
local NEAR2 = NEAR_DEST * NEAR_DEST
local HOP2 = HOP_AHEAD * HOP_AHEAD
local OFF_SCORE = 1000000000

local PT = { x = 0, y = 0, z = 0 }

--- Name of the road the last hop() call selected, or nil.
M.road = nil

local function d2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function npts(route)
    return math.floor((#route - 4) / 3)
end

local function at(route, i)
    local o = 5 + (i - 1) * 3
    return route[o], route[o + 1], route[o + 2]
end

--- Distance squared from (px, py) to the segment (ax, ay)-(bx, by).
local function segd2(px, py, ax, ay, bx, by)
    local abx, aby = bx - ax, by - ay
    local apx, apy = px - ax, py - ay
    local ab2 = abx * abx + aby * aby
    if ab2 < 1 then
        return apx * apx + apy * apy
    end
    local t = (apx * abx + apy * aby) / ab2
    if t < 0 then
        t = 0
    elseif t > 1 then
        t = 1
    end
    local dx = px - (ax + abx * t)
    local dy = py - (ay + aby * t)
    return dx * dx + dy * dy
end

--- End index and step (+1 toward the last point, -1 toward the first)
--- when `dest` is an inn or flight-path end of this road.
local function match_end(route, dx, dy)
    local n = npts(route)
    if n < 2 then return nil end
    local ax, ay = at(route, 1)
    local bx, by = at(route, n)
    local dA = d2(dx, dy, ax, ay)
    local dB = d2(dx, dy, bx, by)
    local okA = route[2] ~= "" and dA <= END2
    local okB = route[3] ~= "" and dB <= END2
    if okB and (not okA or dB <= dA) then
        return n, n, 1
    end
    if okA then
        return n, 1, -1
    end
    return nil
end

local function nearest(route, n, x, y)
    local best_i, best = 1, 1e18
    for i = 1, n do
        local px, py = at(route, i)
        local d = d2(x, y, px, py)
        if d < best then
            best, best_i = d, i
        end
    end
    return best_i, best
end

--- First road point at least HOP_AHEAD yards ahead of the player, toward the end.
local function ahead(route, n, near_i, dir, end_i, hx, hy)
    local i = near_i
    if i ~= end_i then
        local nxt = i + dir
        if nxt >= 1 and nxt <= n then
            i = nxt
        end
    end
    local guard = 0
    while guard < 24 and i ~= end_i do
        local px, py = at(route, i)
        if d2(hx, hy, px, py) >= HOP2 then
            break
        end
        local nxt = i + dir
        if nxt < 1 or nxt > n then
            break
        end
        i = nxt
        guard = guard + 1
    end
    return i
end

--- Road point where the player's line to the destination crosses the road.
local function entry(route, n, hx, hy, dx, dy, dir, end_i)
    local best_i, best = nil, 1e18
    for i = 1, n do
        local toward = (dir == 1 and i < end_i) or (dir == -1 and i > end_i)
        if toward then
            local px, py = at(route, i)
            if d2(px, py, dx, dy) > SKIP2 then
                local sd = segd2(px, py, hx, hy, dx, dy)
                if sd <= CROSS2 then
                    local pd = d2(px, py, hx, hy)
                    if pd < best then
                        best, best_i = pd, i
                    end
                end
            end
        end
    end
    return best_i
end

--- Next recorded point toward an inn or flight master, or nil.
--- `here` and `dest` are positions with x, y, z.
function M.hop(here, dest)
    M.road = nil
    if type(here) ~= "table" or type(dest) ~= "table" then return nil end
    local hx, hy = here.x, here.y
    local dx, dy = dest.x, dest.y
    if type(hx) ~= "number" or type(hy) ~= "number" then return nil end
    if type(dx) ~= "number" or type(dy) ~= "number" then return nil end

    local best_score, best_name = nil, nil
    local best_x, best_y, best_z = nil, nil, nil
    for r = 1, #ROUTES do
        local route = ROUTES[r]
        local n, end_i, dir = match_end(route, dx, dy)
        if n then
            local ni, nd = nearest(route, n, hx, hy)
            local idx, score
            if nd <= ON2 then
                idx = ahead(route, n, ni, dir, end_i, hx, hy)
                score = nd
            else
                idx = entry(route, n, hx, hy, dx, dy, dir, end_i)
                if idx then
                    local px, py = at(route, idx)
                    score = d2(hx, hy, px, py) + OFF_SCORE
                end
            end
            if idx and score then
                local px, py, pz = at(route, idx)
                if d2(px, py, dx, dy) > NEAR2 and (not best_score or score < best_score) then
                    best_score = score
                    best_name = route[1]
                    best_x, best_y, best_z = px, py, pz
                end
            end
        end
    end
    if not best_x then return nil end
    M.road = best_name
    PT.x, PT.y, PT.z = best_x, best_y, best_z
    return PT
end

return M
