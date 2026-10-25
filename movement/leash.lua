-- ============================================================================
-- restedXP_questing
-- movement/leash.lua - the recorded-path corridor (path_runner)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.4.1
-- ============================================================================
-- A recorded path (path_runner) is a polyline. Farther than PATH_LEASH yd
-- from it (a fight pulled the player off) needs_rejoin() is true and
-- rejoin_path() walks back to the nearest point of the line. path_anchor_index
-- tells which segment a position is nearest to, so the run resumes there.
-- The leash only arms once the player has been on the line.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")

local L = {}

local PATH_LEASH = 10.0

local leash, leash_n, leash_src, armed = nil, 0, nil, false

--- Nearest point of the polyline to (x, y): px, py, pz, distance, segment index.
local function project(x, y)
    if not leash or leash_n < 1 then return nil end
    if leash_n == 1 then
        return leash[1], leash[2], leash[3], R.dist2(x, y, leash[1], leash[2]), 1
    end
    local best_d2, bx, by, bz, bi = 1e18, 0, 0, 0, 1
    for i = 1, leash_n - 1 do
        local o = (i - 1) * 3
        local ax, ay, az = leash[o + 1], leash[o + 2], leash[o + 3]
        local cx, cy, cz = leash[o + 4], leash[o + 5], leash[o + 6]
        local vx, vy = cx - ax, cy - ay
        local l2 = vx * vx + vy * vy
        local t = 0
        if l2 > 0.0001 then
            t = ((x - ax) * vx + (y - ay) * vy) / l2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local px, py = ax + vx * t, ay + vy * t
        local dx, dy = x - px, y - py
        local d2 = dx * dx + dy * dy
        if d2 < best_d2 then best_d2, bx, by, bz, bi = d2, px, py, az + (cz - az) * t, i end
    end
    return bx, by, bz, math.sqrt(best_d2), bi
end
L.project = project

--- `waypoints`: a flat {x1,y1,z1,...} array or a list of points.
function L.set_path_leash(waypoints)
    if type(waypoints) ~= "table" or #waypoints < 1 then
        leash, leash_n, leash_src, armed = nil, 0, nil, false
        return
    end
    if waypoints ~= leash_src then
        local flat, n = {}, 0
        if type(waypoints[1]) == "number" then
            for i = 1, math.floor(#waypoints / 3) do
                local k = (i - 1) * 3
                local x, y, z = waypoints[k + 1], waypoints[k + 2], waypoints[k + 3]
                if R.finite(x) and R.finite(y) and R.finite(z) then
                    flat[n * 3 + 1], flat[n * 3 + 2], flat[n * 3 + 3] = x, y, z
                    n = n + 1
                end
            end
        else
            for i = 1, #waypoints do
                local x, y, z = R.xyz(waypoints[i])
                if x then
                    flat[n * 3 + 1], flat[n * 3 + 2], flat[n * 3 + 3] = x, y, z
                    n = n + 1
                end
            end
        end
        if n == 0 then
            leash, leash_n, leash_src, armed = nil, 0, nil, false
            return
        end
        leash, leash_n, leash_src = flat, n, waypoints
    end
    local hx, hy = R.here()
    local d = hx and select(4, project(hx, hy)) or nil
    armed = d ~= nil and d <= PATH_LEASH
end

function L.clear_path_leash()
    leash, leash_n, leash_src, armed = nil, 0, nil, false
end

--- Off the corridor (and not walking an AmeisenNav path that may leave it)?
function L.needs_rejoin()
    if not leash or R.resting then return false end
    local hx, hy = R.here()
    if not hx then return false end
    local _, _, _, d = project(hx, hy)
    if not armed then
        if d and d <= PATH_LEASH then armed = true end
        return false
    end
    if N.busy() then return false end
    return d ~= nil and d > PATH_LEASH
end

--- Walk back to the nearest point of the line.
function L.rejoin_path()
    local hx, hy = R.here()
    if not hx or not leash then return false end
    local px, py, pz = project(hx, hy)
    if not px then return false end
    return N.nav_to({ x = px, y = py, z = pz })
end

--- The segment index nearest `pos` (default: the player).
function L.path_anchor_index(pos)
    local x, y
    if pos then x, y = R.xyz(pos) else x, y = R.here() end
    if not x or not leash then return nil end
    local _, _, _, _, i = project(x, y)
    return i
end

function L.path_offset(pos)
    local x, y
    if pos then x, y = R.xyz(pos) else x, y = R.here() end
    if not x or not leash then return nil end
    local _, _, _, d = project(x, y)
    return d
end

return L
