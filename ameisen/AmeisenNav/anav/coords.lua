-- ============================================================================
-- AmeisenNav
-- anav/coords.lua - ground heights and minimap points (Coords Helper)
-- ============================================================================
-- Version: 1.6.6
-- ============================================================================
-- common/utility/coords_helper (fixed 2026-10-06: the terrain ray now starts
-- extra_height yards above the CHARACTER, not at height 0):
--
--   ground(x, y, guess_z)  the ground under a destination before the path
--       is asked for. A RestedXP waypoint or a map point has no real height;
--       asked at the wrong one the server answers no_path and the client's
--       height search (1.6.2) spends a second request on 9 heights. The ray
--       starts 4 yd above the guess (2 yd indoors, so a ceiling is not hit),
--       then 30 yd above it outdoors (a hill well above the guess). Only
--       within RANGE of the character - farther terrain is not loaded.
--
--   cursor_point()  the world point under the cursor while it is over the
--       minimap (is_cursor_on_minimap + get_cursor_world_pos), for the
--       "walk to the minimap point" key.
-- ============================================================================

local X = require("anav/context")

local G = {}

local RANGE = 150
local LIMIT = 20000

local helper, tried = nil, false
local function coords()
    if not tried then
        tried = true
        local ok, m = pcall(require, "common/utility/coords_helper")
        if ok and type(m) == "table" then helper = m end
    end
    return helper
end

local function finite(n)
    return type(n) == "number" and n == n and n > -LIMIT and n < LIMIT
end

local function fld(v, k)
    local ok, r = pcall(function() return v[k] end)
    if ok then return tonumber(r) end
    return nil
end

local function indoors()
    if type(X.is_indoors) == "function" then
        local ok, v = pcall(X.is_indoors)
        return ok and v == true
    end
    return false
end

--- One terrain read: the ray starts at `start` (world z). nil when the helper
--- is missing, the answer is above the start, or a 0 away from height 0.
local function read(c, x, y, start, pz)
    local ok, h = pcall(c.get_terrain_height, c, x, y, start - pz)
    if not ok or not finite(h) then return nil end
    if h == 0 and math.abs(pz) > 5 then return nil end
    if h > start + 0.5 then return nil end
    return h
end

--- Ground height under (x, y) near `guess_z`, or nil.
function G.ground(x, y, guess_z)
    local c = coords()
    if not c or type(c.get_terrain_height) ~= "function" then return nil end
    if not finite(x) or not finite(y) or not finite(guess_z) then return nil end
    local px, py, pz = X.position()
    if not finite(px) or not finite(pz) then return nil end
    local dx, dy = x - px, y - py
    if dx * dx + dy * dy > RANGE * RANGE then return nil end
    local inside = indoors()
    local h = read(c, x, y, guess_z + (inside and 2 or 4), pz)
    if h == nil and not inside then h = read(c, x, y, guess_z + 30, pz) end
    return h
end

-- ENVIRONMENT (1.7.0): "open" | "indoor" | "cave" for the place the player
-- is in, read at most every C.env_check_every s. A cave is told from a
-- building by the terrain ABOVE the character: get_terrain_height casts down
-- from the player's z + extra_height (coords_helper stub), so a ray started
-- 60 yd up that lands env_cave_cover+ yd above the character hit the ground
-- over its head. Buildings keep is_indoors without that rock cover.
local C = require("anav/config")
local env = { t = -1e9, kind = "open", cover = nil }

function G.environment()
    local okt, t = pcall(core.time)
    t = okt and type(t) == "number" and t or 0
    if t - env.t < (C.env_check_every or 1.0) then return env.kind, env.cover end
    env.t = t
    local inside = indoors()
    local kind = inside and "indoor" or "open"
    local cover = nil
    local c = coords()
    local px, py, pz = X.position()
    if c and type(c.get_terrain_height) == "function" and finite(px) and finite(pz) then
        local ok, h = pcall(c.get_terrain_height, c, px, py, 60)
        if ok and finite(h) and not (h == 0 and math.abs(pz) > 5) and h <= pz + 60.5 then
            cover = h - pz
            if cover >= (C.env_cave_cover or 8.0) then kind = "cave" end
        end
    end
    env.kind, env.cover = kind, cover
    return kind, cover
end

--- The navigation profile for the place the player is in (C.env_profiles),
--- plus its name. Falls back to the flat settings when a profile is missing.
function G.profile()
    local kind = G.environment()
    local P = C.env_profiles and C.env_profiles[kind]
    if type(P) == "table" then return P, kind end
    return {
        length = C.horizon_length, refresh = C.horizon_refresh, spacing = C.waypoint_spacing,
        threshold = C.waypoint_threshold, clearance = C.horizon_clearance,
        object_clearance = C.horizon_object_clearance,
    }, kind
end

--- The world point under the cursor on the minimap, or nil (+ why).
function G.cursor_point()
    local c = coords()
    if not c or type(c.get_cursor_world_pos) ~= "function" then return nil, "no coords_helper" end
    if type(c.is_cursor_on_minimap) == "function" then
        local ok, on = pcall(c.is_cursor_on_minimap, c)
        if ok and on ~= true then return nil, "the cursor is not over the minimap" end
    end
    local ok, w, err = pcall(c.get_cursor_world_pos, c, indoors() and 2 or 30)
    if not ok or w == nil then return nil, tostring(err or "no world point") end
    local x, y, z = fld(w, "x"), fld(w, "y"), fld(w, "z")
    if not finite(x) or not finite(y) or not finite(z) then return nil, "bad world point" end
    return { x = x, y = y, z = z }
end

--- Tests: replace the coords_helper.
function G._set_helper(h) helper, tried = h, true end

return G
