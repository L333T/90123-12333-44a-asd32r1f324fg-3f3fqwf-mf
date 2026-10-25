-- ============================================================================
-- restedXP_questing
-- movement/sight.lua - is the enemy reachable, above ground and in line of
-- sight? Answered by AmeisenNav's navmesh, never by a game raycast.
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.6.0
-- ============================================================================
-- The user (2.313.0): "ensure enemy target is in LoS and not underground or
-- unreachable" - after 2.311.0 removed every game raycast (los_to, trace_line,
-- terrain heights: the M2HitTest crashes). So the answer comes from one
-- AmeisenNav find_path from the player to the enemy (a server request, no
-- native game call; AmeisenNav caches it 10 s on a 4-yard grid):
--   unreachable  no path, or the path ends more than END_XY yd short of the
--                enemy, or the enemy stands END_Z+ yd ABOVE where it ends (a
--                ledge, a roof)
--   underground  the path reaches the enemy's x, y but the walkable ground
--                there is END_Z+ yd ABOVE the enemy (under the floor / map)
--   around       reachable, but the walk is more than STRAIGHT times the
--                straight distance: something (a wall, a rock, a building)
--                stands between - no line of sight
--   clear        reachable and the walk is about the straight line: in sight
-- nil = no answer yet (asked, pending) or no AmeisenNav server - callers then
-- keep their old behaviour. The game's own "Target not in line of sight"
-- refusal (events.lua, movement/range.lua) still applies on top.
-- Each enemy is asked again after TTL s or once it has moved MOVED yd; new
-- requests are at least GAP s apart.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local Sg = {}

local TTL_OK   = 3.0     -- s an answer stands (clear / around)
local TTL_BAD  = 8.0     -- s an unreachable / underground answer stands
local GAP      = 0.15    -- s between new requests
local MOVED    = 5.0     -- yd the enemy may move before it is asked again
local END_XY   = 4.0     -- yd: the path must end this close (flat) to the enemy
local END_Z    = 5.0     -- yd of height between the path's end and the enemy
local STRAIGHT = 1.30    -- walk / straight distance at most, for "in sight"
local NEAR     = 5.0     -- yd: closer than this needs no answer (melee)
local MAX_N    = 200

Sg.TTL_OK, Sg.TTL_BAD, Sg.END_XY, Sg.END_Z, Sg.STRAIGHT, Sg.NEAR = TTL_OK, TTL_BAD, END_XY, END_Z, STRAIGHT, NEAR

local cache, cache_n = {}, 0
local next_ask = 0

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function xyz(p)
    if p == nil then return nil end
    local ok, x, y, z = pcall(function() return p.x, p.y, p.z end)
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
    return nil
end

local function nav()
    local ok, N = pcall(require, "movement/nav")
    if ok and type(N) == "table" and type(N.path_probe) == "function" then return N end
    return nil
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "sight", fmt, ...) end
end

local REFUSAL = { "no_path", "end_off_mesh", "unreachable", "not on navmesh", "422" }

local function refused(info)
    local s = string.lower(tostring(type(info) == "table" and (info.reason or info.code or info.error) or info or ""))
    for i = 1, #REFUSAL do
        if s:find(REFUSAL[i], 1, true) then return true end
    end
    return false
end

--- The verdict for a finished path (exposed for the tests).
function Sg.judge(px, py, pz, ux, uy, uz, pts)
    if type(pts) ~= "table" or #pts < 2 then return "unreachable" end
    local last = pts[#pts]
    local lx, ly, lz = xyz(last)
    if not lx then return "unreachable" end
    local short = math.sqrt((lx - ux) ^ 2 + (ly - uy) ^ 2)
    local dz = uz - lz                 -- > 0: the enemy is above the path's end
    if dz < -END_Z and short <= END_XY * 2 then return "underground" end
    if short > END_XY or dz > END_Z then return "unreachable" end
    local walk, ax, ay, az = 0, px, py, pz
    for i = 1, #pts do
        local x, y, z = xyz(pts[i])
        if x then
            walk = walk + math.sqrt((x - ax) ^ 2 + (y - ay) ^ 2 + (z - az) ^ 2)
            ax, ay, az = x, y, z
        end
    end
    local straight = math.sqrt((ux - px) ^ 2 + (uy - py) ^ 2 + (uz - pz) ^ 2)
    if straight <= NEAR or walk <= straight * STRAIGHT + 1 then return "clear" end
    return "around"
end

--- "clear" | "around" | "unreachable" | "underground" | nil (unknown yet).
function Sg.verdict(player, unit)
    if not player or not unit then return nil end
    local guid = call(unit.get_guid, unit)
    local px, py, pz = xyz(call(player.get_position, player))
    local ux, uy, uz = xyz(call(unit.get_position, unit))
    if guid == nil or not px or not ux then return nil end
    local straight = math.sqrt((ux - px) ^ 2 + (uy - py) ^ 2)
    if straight <= NEAR and math.abs(uz - pz) <= END_Z then return "clear" end
    local now = izi.now()
    local e = cache[guid]
    if e then
        local ttl = (e.v == "unreachable" or e.v == "underground") and TTL_BAD or TTL_OK
        local moved = math.sqrt((ux - e.ux) ^ 2 + (uy - e.uy) ^ 2)
        if e.pending and (now - e.t) < 5 then return e.v end
        if not e.pending and (now - e.t) < ttl and moved < MOVED then return e.v end
    end
    local N = nav()
    if not N or now < next_ask then return e and e.v or nil end
    next_ask = now + GAP
    if not e then
        if cache_n >= MAX_N then cache, cache_n = {}, 0 end
        cache_n = cache_n + 1
    end
    local old = e and e.v or nil
    local entry = { t = now, ux = ux, uy = uy, uz = uz, v = old, pending = true }
    cache[guid] = entry
    local name = tostring(call(unit.get_name, unit) or "?")
    local sent = N.path_probe({ x = px, y = py, z = pz }, { x = ux, y = uy, z = uz }, function(pts, ok, info)
        entry.pending = false
        entry.t = izi.now()
        if not pts and ok ~= true and not refused(info) then
            entry.v = nil                -- server trouble: no answer, not "unreachable"
            return
        end
        entry.v = Sg.judge(px, py, pz, ux, uy, uz, pts)
        if entry.v ~= old and entry.v ~= "clear" then
            trail("%s at %.0f yd: %s", name, straight, entry.v)
        end
    end)
    if not sent then
        entry.pending = false
        entry.v = old
    end
    return entry.v
end

--- true / false / nil (unknown): is `unit` above ground and reachable?
function Sg.reachable(player, unit)
    local v = Sg.verdict(player, unit)
    if v == nil then return nil end
    return v ~= "unreachable" and v ~= "underground"
end

--- Is a navmesh answer possible at all (AmeisenNav loaded)?
function Sg.available()
    local N = nav()
    return N ~= nil and type(N.nav_ready) == "function" and N.nav_ready() == true
end

function Sg.reset()
    cache, cache_n, next_ask = {}, 0, 0
end

return Sg
