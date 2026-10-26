-- ============================================================================
-- Master Farmer - restedXP_questing
-- movement/trace.lua - ray helpers for Sentinel walks (1.32.0)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- ============================================================================
-- 2026-10-25 (user: "Remove Raycast and traceline rules. Use similar helper
-- logic that the Helper folder contains for Raycast and Traceline that Sentinel
-- can use and implement it"). Desktop\Helper trace.lua / move.lua reworked for a
-- bot that never steers with keys over a Sentinel walk: the rays only LOOK; what
-- they see goes to Sentinel (an avoidance zone + a re-plan) or is one jump.
--
--   T.hit(a, b, flags) / T.clear       one ray (true = something in the way)
--   T.los_xyz(point)                   eye-level line of sight to a point
--   T.path_blocked(me)                 "front" / "left" / "right" / false - the
--                                      Helper's 3-height probes 1 yd ahead
--   T.obstacle_height(me)              highest thing in the next 2 yd above the feet
--   T.leg_blocked(a, b)                knee / chest rays along a walk leg
--   T.clear_spot_near(dest, from)      Helper step_to_xyz: a spot 3-5 yd round
--                                      `dest` with a clear line from `from`
--   T.tick(t, ctx)                     every pulse while Sentinel walks: no
--                                      progress for STALL_S with "front" blocked
--                                      -> a low obstacle (JUMP_MIN..JUMP_MAX yd)
--                                      is jumped, a wall gets an avoidance zone
--                                      (Sentinel walks round it itself)
--
-- SAFEGUARDS (the A* fallback's, movement/astar.lua): T.ON kill switch; at most
-- T.BUDGET rays a frame; a self-check ray down through the ground under the
-- player must hit, else off for the session; T.ERRORS call errors -> off for the
-- session (logged). Never the EntityRender flag (raises / crashed classic).
-- ============================================================================

local R = require("movement/core")

local T = {}

T.ON = true                      -- KILL SWITCH
T.BUDGET = 40                    -- rays per frame (a frame = one R.now() value)
T.ERRORS = 3
T.STALL_S = 0.8                  -- no progress this long with Sentinel walking
T.STALL_YD = 0.4
T.JUMP_MIN, T.JUMP_MAX = 0.45, 1.7   -- yd above the feet: a step Sentinel's walk can hop
T.JUMP_GAP = 2.0
T.WALL_GAP = 5.0
T.WALL_R = 2.5                   -- yd: the avoidance zone put on a wall ahead
T.LOOK_GAP = 0.25                -- s between two looks ahead

local st = { off = false, why = nil, errors = 0, checked = false, frame_t = -1, frame_n = 0,
    pos = nil, pos_t = -1e9, look_t = -1e9, jump_t = -1e9, wall_t = -1e9 }
T._st = st
T.stats = { rays = 0, jumps = 0, walls = 0 }

local vec3_mod = nil
local function v3(x, y, z)
    if vec3_mod == nil then
        local ok, m = pcall(require, "common/geometry/vector_3")
        vec3_mod = (ok and type(m) == "table") and m or false
    end
    if vec3_mod then return vec3_mod.new(x, y, z) end
    return { x = x, y = y, z = z }
end

local FLAGS = nil
local function flags()
    if FLAGS == nil then
        local ok, enums = pcall(require, "common/enums")
        local cf = ok and type(enums) == "table" and enums.collision_flags or nil
        local function c(...)
            local okc, v = pcall(function(...) return cf.combine(...) end, ...)
            return okc and type(v) == "number" and v or nil
        end
        FLAGS = {
            COLLISION = c("DoodadCollision", "WmoCollision", "EntityCollision", "Terrain"),
            WALK = c("DoodadCollision", "WmoCollision"),
            LOS = c("WmoCollision", "DoodadCollision", "LineOfSight"),
            GROUND = c("DoodadCollision", "WmoCollision", "Terrain"),
        }
        if not (FLAGS.COLLISION and FLAGS.WALK and FLAGS.LOS and FLAGS.GROUND) then FLAGS = false end
    end
    return FLAGS or nil
end

local function turn_off(why)
    if st.off then return end
    st.off, st.why = true, why
    R.log("Ray helpers switched off for this session: " .. tostring(why))
    R.trail("trace", "switched off: %s", tostring(why))
end

function T.enabled() return T.ON and not st.off end

--- One ray; true = something in the way, false = clear, nil = no ray (off, over
--- budget, an error).
function T.hit(a, b, which)
    if not T.enabled() then return nil end
    local f = flags()
    if not f then turn_off("no collision flags") return nil end
    local now = R.now()
    if now ~= st.frame_t then st.frame_t, st.frame_n = now, 0 end
    if st.frame_n >= T.BUDGET then return nil end
    st.frame_n = st.frame_n + 1
    T.stats.rays = T.stats.rays + 1
    local ok, hit = pcall(core.graphics.trace_line, v3(a.x, a.y, a.z), v3(b.x, b.y, b.z), f[which or "COLLISION"])
    if not ok then
        st.errors = st.errors + 1
        R.trail("trace", "trace_line failed (%d of %d)", st.errors, T.ERRORS)
        if st.errors >= T.ERRORS then turn_off("trace_line calls fail") end
        return nil
    end
    return hit == true
end
function T.clear(a, b, which)
    local h = T.hit(a, b, which)
    if h == nil then return nil end
    return not h
end

--- The self-check (once): a ray down through the ground under the player must hit.
function T.ready()
    if not T.enabled() then return false end
    if st.checked then return true end
    local x, y, z = R.here()
    if not x then return false end
    local h = T.hit({ x = x, y = y, z = z + 1.5 }, { x = x, y = y, z = z - 2.0 }, "GROUND")
    if h == nil then return false end
    if h ~= true then turn_off("self-check: a ray through the ground under the player did not hit") return false end
    st.checked = true
    R.trail("trace", "self-check passed (trace_line true = hit)")
    return true
end

local function body(me)
    local h = me and select(2, pcall(function() return me:get_height() end))
    if type(h) ~= "number" or h <= 0 or h > 6 then h = 2 end
    return h
end
local function facing(me)
    local ok, f = pcall(function() return me:get_rotation() end)
    return ok and type(f) == "number" and f or nil
end
local function off(x, y, f, ang, reach)
    return x + math.cos(f + ang) * reach, y + math.sin(f + ang) * reach
end

--- Eye-level line of sight from the player to a point (Helper los_xyz).
function T.los_xyz(p, me)
    me = me or R.me()
    local x, y, z = R.here()
    if not x or not p then return nil end
    local h = body(me)
    return T.clear({ x = p.x, y = p.y, z = p.z + h }, { x = x, y = y, z = z + h }, "LOS")
end

local function side_blocked(ax, ay, z, bx, by, h)
    local probes = { { 0.3, 0.3 }, { h * 0.5, h * 0.5 }, { h, h } }      -- feet / waist / head
    for i = 1, #probes do
        local r = T.hit({ x = ax, y = ay, z = z + probes[i][1] }, { x = bx, y = by, z = z + probes[i][2] }, "COLLISION")
        if r == nil then return nil end
        if r then return true end
    end
    return false
end

--- "front" / "left" / "right" / false: the Helper's probes 1 yd ahead of the
--- player (front first). nil when no ray could be cast.
function T.path_blocked(me)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f then return nil end
    local h = body(me)
    local fx, fy = off(x, y, f, 0, 1)
    local sx, sy = off(x, y, f, 0, 1 / 3)
    local a = side_blocked(x, y, z, sx, sy, h)
    if a == nil then return nil end
    if a or side_blocked(x, y, z, fx, fy, h) then return "front" end
    local rx, ry = off(x, y, f, 1.5708, 1)
    local frx, fry = off(fx, fy, f, 1.5708, 1)
    if side_blocked(rx, ry, z, frx, fry, h) then return "right" end
    local lx, ly = off(x, y, f, -1.5708, 1)
    local flx, fly = off(fx, fy, f, -1.5708, 1)
    if side_blocked(lx, ly, z, flx, fly, h) then return "left" end
    return false
end

--- The highest thing above the feet in the next `yards` (Helper should_jump):
--- three samples, a 6-step height search each. nil when no ray.
function T.obstacle_height(me, yards)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f then return nil end
    yards = yards or 2
    local top = 0
    for _, d in ipairs({ 0.7, 1.2, yards }) do
        local px, py = off(x, y, f, 0, d)
        local first = T.hit({ x = px, y = py, z = z + 3 }, { x = px, y = py, z = z + 0.05 }, "COLLISION")
        if first == nil then return nil end
        if first then
            local lo, hi = 0.05, 3.0
            for _ = 1, 6 do
                local mid = (lo + hi) * 0.5
                local r = T.hit({ x = px, y = py, z = z + 3 }, { x = px, y = py, z = z + mid }, "COLLISION")
                if r == nil then return nil end
                if r then lo = mid else hi = mid end
            end
            if lo > top then top = lo end
        end
    end
    return top
end

--- Knee and chest rays along a walk leg a -> b (at most the first 6 yd). true =
--- blocked, false = clear, nil = no ray.
function T.leg_blocked(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.5 then return false end
    local k = math.min(1, 6 / d)
    local e = { x = a.x + dx * k, y = a.y + dy * k, z = a.z + ((b.z or a.z) - a.z) * k }
    for _, hgt in ipairs({ 0.9, 1.8 }) do
        local r = T.hit({ x = a.x, y = a.y, z = a.z + hgt }, { x = e.x, y = e.y, z = e.z + hgt }, "WALK")
        if r == nil then return nil end
        if r then return true end
    end
    return false
end

--- A spot `near`..`far` yd round `dest` with a clear line from `from` at eye
--- level and knee level (Helper step_to_xyz, 24 directions from the side facing
--- `from` first). nil when none (or no rays).
function T.clear_spot_near(dest, from, near_yd, far_yd)
    if not dest or not from then return nil end
    near_yd, far_yd = near_yd or 3, far_yd or 5
    local yaw = math.atan2(from.y - dest.y, from.x - dest.x)
    for i = 0, 23 do
        local step = math.floor((i + 1) / 2) * (i % 2 == 0 and 1 or -1)
        local a = yaw + math.rad(15) * step
        local n = { x = dest.x + math.cos(a) * near_yd, y = dest.y + math.sin(a) * near_yd, z = dest.z }
        local f = { x = dest.x + math.cos(a) * far_yd, y = dest.y + math.sin(a) * far_yd, z = dest.z }
        local ok1 = T.clear({ x = from.x, y = from.y, z = from.z + 1.8 }, { x = f.x, y = f.y, z = f.z + 1.8 }, "LOS")
        if ok1 == nil then return nil end
        if ok1 then
            local ok2 = T.clear({ x = from.x, y = from.y, z = from.z + 0.9 }, { x = n.x, y = n.y, z = n.z + 0.9 }, "WALK")
            if ok2 == nil then return nil end
            if ok2 then return n end
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- the walk assistant
-- ----------------------------------------------------------------------------
--- Every pulse. ctx = { walking, no_jump, riding, mounted_flying, avoid(p, r, why),
--- jump() }. True when it acted.
function T.tick(t, ctx)
    if not T.enabled() or not ctx or not ctx.walking then st.pos = nil return false end
    local x, y, z = R.here()
    if not x then return false end
    if not st.pos or R.dist3(x, y, z, st.pos.x, st.pos.y, st.pos.z) > T.STALL_YD then
        st.pos, st.pos_t = { x = x, y = y, z = z }, t
        return false
    end
    if t - st.pos_t < T.STALL_S or t - st.look_t < T.LOOK_GAP then return false end
    st.look_t = t
    if not T.ready() then return false end
    local me = R.me()
    local blocked = T.path_blocked(me)
    if blocked ~= "front" then return false end
    local h = T.obstacle_height(me)
    if h == nil then return false end
    if h >= T.JUMP_MIN and h <= T.JUMP_MAX then
        if ctx.no_jump or ctx.riding or ctx.mounted_flying or t - st.jump_t < T.JUMP_GAP then return false end
        st.jump_t = t
        T.stats.jumps = T.stats.jumps + 1
        R.trail("trace", "an obstacle %.1f yd high ahead, no progress %.1f s - jump", h, t - st.pos_t)
        if type(ctx.jump) == "function" then pcall(ctx.jump) end
        st.pos = nil
        return true
    end
    if h > T.JUMP_MAX and t - st.wall_t >= T.WALL_GAP and type(ctx.avoid) == "function" then
        st.wall_t = t
        local f = facing(me) or 0
        local wx, wy = off(x, y, f, 0, 1.5)
        T.stats.walls = T.stats.walls + 1
        R.trail("trace", "a wall %.1f yd high ahead, no progress %.1f s - avoidance zone %.1f yd, re-plan", h, t - st.pos_t, T.WALL_R)
        pcall(ctx.avoid, { x = wx, y = wy, z = z }, T.WALL_R, "wall ahead (ray)")
        st.pos = nil
        return true
    end
    return false
end

function T.reset()
    st.pos, st.look_t, st.jump_t, st.wall_t = nil, -1e9, -1e9, -1e9
end

return T
