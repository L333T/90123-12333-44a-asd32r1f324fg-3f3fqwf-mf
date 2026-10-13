-- ============================================================================
-- Master Farmer - Grindbot
-- movement/core.lua - shared state and helpers of the movement layer
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.2.0
-- ============================================================================
-- 3.0.0 MOVEMENT RECODE. Every walk is AmeisenNav's (_G.AmeisenNav.client,
-- the 2.0.0 navigation API): it paths on the navmesh, owns the walker
-- (simple_movement / its input driver), traces walls with the safe collision
-- mask, avoids objects and recovers from being stuck. This layer only decides
-- WHERE to go and WHEN to stand still; it never touches simple_movement while
-- AmeisenNav is loaded (docs/API.md: "While AmeisenNav is moving, do not
-- drive simple_movement yourself"). It casts no ray of its own.
--
-- Modules (all small, one job each):
--   core    shared state R, positions, distances, logging
--   zones   blacklisted areas and danger circles (pure bookkeeping)
--   nav     AmeisenNav travel: move_to / follow_path / stop / pause,
--           failures, reachability cache, route-height fix
--   combat  closing on a target and standing in range (AmeisenNav seamless
--           re-paths), retreat (client:kite), the in-position latch
--   locks   rest / cast / channel / loot holds, backpedal
--   range   facing, line of sight, arrival and fight range
--   leash   the recorded-path corridor path_runner keeps to
--   sight   reachable / underground / in sight from the navmesh (no ray)
-- ============================================================================

local R = {}

R.TAG = "[Master Farmer - Grindbot]"

-- shared runtime state (one table; modules read and write their own keys)
R.debug_on = false
R.resting = false
R.quiet_until = 0            -- a stop just happened: callers wait (is_quiet)
R.last_spell_id, R.last_spell_target, R.last_spell_t = nil, nil, 0

local sqrt = math.sqrt
local LIMIT = 20000

function R.now()
    local ok, t = pcall(core.time)
    if ok and type(t) == "number" then return t end
    return 0
end

local function finite(n)
    return type(n) == "number" and n == n and n > -LIMIT and n < LIMIT
end
R.finite = finite

--- x, y, z of a vec3, a {x,y,z} table or a positional {x, y, z} row; nil when
--- any is missing or not finite.
function R.xyz(p)
    if p == nil then return nil end
    local ok, x, y, z = pcall(function()
        local a, b, c = p.x, p.y, p.z
        if a == nil and type(p) == "table" then a, b, c = p[1], p[2], p[3] end
        return a, b, c
    end)
    if not ok or not finite(x) or not finite(y) or not finite(z) then return nil end
    return x, y, z
end

function R.point(p)
    local x, y, z = R.xyz(p)
    if not x then return nil end
    return { x = x, y = y, z = z }
end

--- The local player (valid) or nil.
function R.me()
    local ok, p = pcall(function() return core.object_manager.get_local_player() end)
    if not ok or not p then return nil end
    local okv, v = pcall(p.is_valid, p)
    if okv and v == false then return nil end
    return p
end

--- The player's x, y, z or nil.
function R.here()
    local me = R.me()
    if not me then return nil end
    local ok, pos = pcall(me.get_position, me)
    if not ok then return nil end
    return R.xyz(pos)
end

function R.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

function R.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return sqrt(dx * dx + dy * dy + dz * dz)
end

--- Is `u` a live game object (valid, not dead)?
function R.alive(u)
    if u == nil then return false end
    local okv, v = pcall(u.is_valid, u)
    if not okv or v ~= true then return false end
    local okd, d = pcall(u.is_dead, u)
    return not (okd and d == true)
end

function R.guid(u)
    if u == nil then return nil end
    local ok, g = pcall(u.get_guid, u)
    if ok then return g end
    return nil
end

-- ----------------------------------------------------------------------------
-- logging: errorlog trail (always) and the debug console (move_debug on)
-- ----------------------------------------------------------------------------
local el = nil
function R.trail(tag, fmt, ...)
    if el == nil then
        local ok, m = pcall(require, "errorlog")
        el = (ok and type(m) == "table" and type(m.trail) == "function") and m or false
    end
    if el then pcall(el.trail, tag, fmt, ...) end
end

function R.log(text)
    pcall(core.log, R.TAG .. " " .. tostring(text))
end

function R.dlog(tag, text)
    if not R.debug_on then return end
    pcall(core.log, R.TAG .. " [" .. tostring(tag) .. "] " .. tostring(text))
end

return R
