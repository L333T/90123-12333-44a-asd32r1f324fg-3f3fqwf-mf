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
--   T.hit_z(x, y, top, bottom, which)  the height a vertical ray meets something
--                                      (an 8-step binary search: trace_line only
--                                      says hit / no hit) - false = nothing there
--   T.ground_z(p)                      the floor under p: core height query, else
--                                      a ray snap (WMO floors / doodads it misses)
--   T.jump_ok(me, h)                   room to hop an h yd obstacle: head clear above
--                                      it, and no drop past DROP_MAX behind it
--   T.tick(t, ctx)                     every pulse while Sentinel walks: no
--                                      progress for STALL_S with "front" blocked
--                                      -> a low obstacle (JUMP_MIN..JUMP_MAX yd)
--                                      is jumped, a wall gets an avoidance zone
--                                      (Sentinel walks round it itself); 2026-10-26:
--                                      a step with no headroom / a drop behind it is
--                                      a wall too, and a body snagged on a corner at
--                                      the side ("left" / "right") gets a small zone
--                                      on that side
-- 2026-10-26 (user: "Add traceline and raycast logic using logic from this example
-- or similar" - the Orca A* port): hit_z, ground_z, the jump checks and the side
-- snag are from it; its A* is Zygor's movement/astar.lua already.
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
T.DROP_MAX = 6.0                 -- yd of fall behind an obstacle that is still jumped
T.SNAG_GAP = 4.0                 -- s between two side-snag zones
T.SNAG_R = 1.2                   -- yd: the zone put on a corner at the side
T.GAP_MAX = 12                   -- yd scanned to each side of a wall ahead (gap_counts)
T.GAP_ZONES = 4                  -- zones laid along the wall's long side
T.GAP_ZONE_R, T.GAP_STEP = 1.2, 2.0
T.PEND_S = 1.0                   -- s a wall seen ahead waits for its gap scan
-- 2026-10-28 (user: "Always dismount when attempting to enter doorways, use get
-- player height when mounted, to check entrances to keep player from getting
-- stuck"): get_height() answers the body we have NOW, so mounted it is the
-- taller body. A lintel between the on-foot head and the mounted head is a
-- doorway the player fits through on foot and the mount does not - we come off
-- the mount before it, not after we are wedged in it.
T.DOOR_LOOK = 3.0                -- yd ahead probed for a low entrance
T.DOOR_GAP = 3.0                 -- s between two dismounts
T.DOOR_CLEAR = 0.2               -- yd the mounted body must exceed the on-foot one by
T.FOOT_H = 2.0                   -- the on-foot body height until a real one is read

local st = { off = false, why = nil, errors = 0, checked = false, frame_t = -1, frame_n = 0,
    pos = nil, pos_t = -1e9, look_t = -1e9, jump_t = -1e9, wall_t = -1e9, snag_t = -1e9, wall_pend = nil,
    door_t = -1e9, foot_h = nil,
    self_t = -1e9, self_n = 0 }        -- the self-check's own retry clock
T._st = st
T.stats = { rays = 0, jumps = 0, walls = 0, snags = 0, gaps = 0, doors = 0 }

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
    if not f[which or "COLLISION"] then return nil end
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

-- SELF-CHECK (auto_bg 2.62.0, session log 2026-10-28: "Ray helpers switched off
-- for this session: self-check: a ray through the ground under the player did
-- not hit", in BOTH plugin loads of one Warsong Gulch session - so the local A*
-- fallback was off for the whole match).
--
-- A trace_line that THROWS is a broken client and still stops every ray user at
-- once (that rule does not change). A trace_line that ANSWERS FALSE is a
-- different thing: it says this one segment hit nothing. The check used to
-- treat the very first such answer as proof the client could not trace, for the
-- rest of the session.
--
-- A miss is expected from plenty of honest positions: in the air after a jump or
-- a knock-back, swimming (the bed can be further down than the segment reached),
-- riding a lift, standing on a thin WMO edge. So the SAMPLE has to be
-- trustworthy before its answer counts - not falling, not swimming, not flying -
-- and it takes SELF_TRIES misses from such positions, SELF_GAP s apart, to
-- conclude the client cannot trace at all. A budget or error answer (nil) is not
-- counted as a miss.
--
-- The segment is also deeper than it was (was +1.5 / -2.0, a 3.5 yd window
-- centred on the feet): the question is only "is there anything under me", and a
-- longer downward leg cannot turn a real hit into a miss.
local SELF_TRIES, SELF_GAP = 5, 2.0
local SELF_UP, SELF_DOWN = 2.0, 5.0

--- Is the player somewhere a ground ray is a fair test? Every predicate is in
--- the live stub (game_object.lua is_falling / is_swimming / is_flying,
--- core.character.is_swimming).
local function sample_ok(me)
    if me == nil then return false end
    local function yes(name)
        local ok, v = pcall(function() return me[name](me) end)
        return ok and v == true
    end
    if yes("is_falling") or yes("is_swimming") or yes("is_flying") then return false end
    local oks, sw = pcall(function() return core.character.is_swimming() end)
    if oks and sw == true then return false end
    return true
end
T._sample_ok = sample_ok

--- The self-check: a ray down through the ground under the player must hit.
--- False until it has passed; it keeps trying rather than condemning the client
--- on one miss.
function T.ready()
    if not T.enabled() then return false end
    if st.checked then return true end
    local now = R.now()
    if now - (st.self_t or -1e9) < SELF_GAP then return false end
    if not sample_ok(R.me()) then return false end
    local x, y, z = R.here()
    if not x then return false end
    st.self_t = now
    local h = T.hit({ x = x, y = y, z = z + SELF_UP }, { x = x, y = y, z = z - SELF_DOWN }, "GROUND")
    if h == nil then return false end                     -- budget or error, not an answer
    if h == true then
        st.checked = true
        R.trail("trace", "self-check passed (trace_line true = hit)%s",
            (st.self_n or 0) > 0 and string.format(" after %d miss(es)", st.self_n) or "")
        return true
    end
    st.self_n = (st.self_n or 0) + 1
    R.trail("trace", "self-check miss %d of %d: a ray %.0f yd down at %.0f %.0f %.0f hit nothing",
        st.self_n, SELF_TRIES, SELF_UP + SELF_DOWN, x, y, z)
    if st.self_n >= SELF_TRIES then
        turn_off(string.format(
            "self-check: %d rays through the ground under the player did not hit (%d s apart, on foot each time)",
            st.self_n, SELF_GAP))
    end
    return false
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

--- Mounted right now? (get_height answers the mounted body while we are.)
local function mounted(me)
    if not me then return false end
    local ok, v = pcall(function() return me:is_mounted() end)
    return ok and v == true
end

--- The body height the player has ON FOOT. get_height() answers the current
--- body, so it is read whenever we are not mounted and remembered for while we
--- are. No rays.
local function foot_height(me)
    if not mounted(me) then
        local h = body(me)
        if h > 0 then st.foot_h = h end
    end
    return st.foot_h or T.FOOT_H
end
T._foot_height = foot_height

--- A doorway / entrance ahead low enough to stop the mount but not the player on
--- foot - true, false, or nil when no ray could be cast. At each probe distance:
--- clear at the waist and at the on-foot head (we fit through on foot) and
--- blocked at the mounted head (the mount does not). Blocked at the waist is a
--- WALL, not a doorway, and is left to the wall logic.
function T.low_entrance(me)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f then return nil end
    local foot = foot_height(me)
    local ride = body(me)                       -- mounted: the taller body
    if ride <= foot + T.DOOR_CLEAR then return false end
    for _, d in ipairs({ 1.0, 2.0, T.DOOR_LOOK }) do
        local px, py = off(x, y, f, 0, d)
        local waist = T.hit({ x = x, y = y, z = z + foot * 0.5 }, { x = px, y = py, z = z + foot * 0.5 }, "COLLISION")
        if waist == nil then return nil end
        if not waist then
            local head = T.hit({ x = x, y = y, z = z + foot }, { x = px, y = py, z = z + foot }, "COLLISION")
            if head == nil then return nil end
            if not head then
                local top = T.hit({ x = x, y = y, z = z + ride }, { x = px, y = py, z = z + ride }, "COLLISION")
                if top == nil then return nil end
                if top then return true end
            end
        end
    end
    return false
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

--- The height where a ray from `top` straight down to `bottom` first meets
--- something (the Orca port's hit_z) - a binary search, trace_line only says hit
--- or not. false = nothing between, nil = no ray (off / budget / an error).
function T.hit_z(x, y, top, bottom, which, steps)
    local first = T.hit({ x = x, y = y, z = top }, { x = x, y = y, z = bottom }, which)
    if first == nil then return nil end
    if not first then return false end
    local lo, hi = bottom, top
    for _ = 1, steps or 8 do
        local mid = (lo + hi) * 0.5
        local r = T.hit({ x = x, y = y, z = top }, { x = x, y = y, z = mid }, which)
        if r == nil then return nil end
        if r then lo = mid else hi = mid end
    end
    return lo
end

--- The floor under `p` - the game's height query, else a ray snap down (the Orca
--- port's ground_z / Handler:expand). nil when unknown.
function T.ground_z(p)
    if not p then return nil end
    local ok, h = pcall(core.get_height_for_position, v3(p.x, p.y, p.z))
    if ok and type(h) == "number" and h == h and h ~= 0 then return h end
    local z = T.hit_z(p.x, p.y, p.z + 3, p.z - 20, "GROUND", 10)
    return z or nil
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
        local hz = T.hit_z(px, py, z + 3, z + 0.05, "COLLISION", 6)
        if hz == nil then return nil end
        if hz and hz - z > top then top = hz - z end
    end
    return top
end

--- Room to hop an obstacle `h` yd high ahead: the head clear above its top 1.2 yd
--- ahead, and no fall past DROP_MAX 2.5 yd ahead. true / false, why / nil (no ray).
function T.jump_ok(me, h)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f or not h then return nil end
    local top = z + h
    local ax, ay = off(x, y, f, 0, 1.2)
    local r = T.hit({ x = ax, y = ay, z = top + 0.15 }, { x = ax, y = ay, z = top + 0.15 + body(me) }, "COLLISION")
    if r == nil then return nil end
    if r then return false, "no headroom over it" end
    local lx, ly = off(x, y, f, 0, 2.5)
    local g = T.ground_z({ x = lx, y = ly, z = top + 0.5 })
    if g and z - g > T.DROP_MAX then return false, string.format("a %.0f yd drop behind it", z - g) end
    return true
end

--- How many yards the wall ahead runs to each side (the Orca A* port's
--- _howManyLeft / _howManyRight): for i = 1..max yd beside the player, a ray from
--- that side point to the same point 1 yd ahead at head and waist height; the
--- count is the run of blocked offsets from the player out. left, right / nil
--- (no ray). `pose` = { x, y, z, f, h } freezes the position it was taken from.
function T.gap_counts(pose, max)
    if not pose then return nil end
    max = max or T.GAP_MAX
    local fx, fy = off(pose.x, pose.y, pose.f, 0, 1)
    local out = {}
    for s, ang in ipairs({ -1.5708, 1.5708 }) do
        local n = 0
        for i = 1, max do
            local ax, ay = off(pose.x, pose.y, pose.f, ang, i)
            local bx, by = off(fx, fy, pose.f, ang, i)
            local blocked = false
            for _, hz in ipairs({ pose.h, pose.h * 0.5 }) do
                local r = T.hit({ x = ax, y = ay, z = pose.z + hz }, { x = bx, y = by, z = pose.z + hz }, "COLLISION")
                if r == nil then return nil end
                if r then blocked = true break end
            end
            if not blocked then break end
            n = n + 1
        end
        out[s] = n
    end
    return out[1], out[2]
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
-- 4.36.0 WALL GAP (the Orca A* port's _howManyLeft / _howManyRight, user
-- 2026-10-27): a wall ahead is measured to both sides one look later (a fresh
-- ray budget), and the short side is left open - small zones are laid along
-- the long side's stretch of the wall, so Sentinel's re-plan goes round the
-- short end. Orca strafes there; here the keys stay Sentinel's (rule 4).
-- No count (no rays) or no end within GAP_MAX either side: one zone straight
-- ahead, as before.
local function place_wall(pend, ctx)
    local l, r = T.gap_counts(pend, T.GAP_MAX)
    local f = pend.f
    T.stats.walls = T.stats.walls + 1
    if l and r and (l > 0 or r > 0) and not (l >= T.GAP_MAX and r >= T.GAP_MAX) and l ~= r then
        local long_ang = (r > l) and 1.5708 or -1.5708
        local long = math.max(l, r)
        local open = (r > l) and "left" or "right"
        local cx, cy = off(pend.x, pend.y, f, 0, 1.5)
        local n = 0
        local k = 0
        while n < T.GAP_ZONES and k <= long do
            local zx, zy = off(cx, cy, f, long_ang, k)
            pcall(ctx.avoid, { x = zx, y = zy, z = pend.z }, T.GAP_ZONE_R, "wall ahead, open " .. open .. " (ray gap)")
            n = n + 1
            k = k + T.GAP_STEP
        end
        T.stats.gaps = T.stats.gaps + 1
        R.trail("trace", "a wall %.1f yd high ahead runs %d yd left / %d yd right - %d zones on the long side, round the %s",
            pend.hgt, l, r, n, open)
        return true
    end
    local wx, wy = off(pend.x, pend.y, f, 0, 1.5)
    R.trail("trace", "a wall %.1f yd high ahead%s (gap %s / %s) - avoidance zone %.1f yd, re-plan", pend.hgt,
        pend.why and (" (" .. pend.why .. ")") or "", tostring(l), tostring(r), T.WALL_R)
    pcall(ctx.avoid, { x = wx, y = wy, z = pend.z }, T.WALL_R, "wall ahead (ray)")
    return true
end

--- Every pulse. ctx = { walking, no_jump, riding, mounted_flying, avoid(p, r, why),
--- jump() }. True when it acted.
function T.tick(t, ctx)
    foot_height(R.me())                         -- no rays; keeps the on-foot height current
    if not T.enabled() or not ctx or not ctx.walking then st.pos, st.wall_pend = nil, nil return false end
    local x, y, z = R.here()
    if not x then return false end
    -- DOORWAY: this runs while we are still MOVING (the checks below only look
    -- once a walk has stalled) - the point is to be off the mount before the
    -- entrance. Never in the air, and the walk is not stopped: Sentinel keeps the
    -- path it has, we are simply shorter when we reach the gap.
    if type(ctx.dismount) == "function" and not ctx.mounted_flying and mounted(R.me())
        and t - st.door_t >= T.DOOR_GAP and T.ready() then
        if T.low_entrance() == true then
            st.door_t = t
            T.stats.doors = T.stats.doors + 1
            R.trail("trace", "an entrance ahead is too low for the mount (mounted body %.1f yd, on foot %.1f) - dismounting",
                body(R.me()), st.foot_h or T.FOOT_H)
            pcall(ctx.dismount)
            return true
        end
    end
    if not st.pos or R.dist3(x, y, z, st.pos.x, st.pos.y, st.pos.z) > T.STALL_YD then
        st.pos, st.pos_t = { x = x, y = y, z = z }, t
        return false
    end
    if t - st.pos_t < T.STALL_S or t - st.look_t < T.LOOK_GAP then return false end
    st.look_t = t
    if not T.ready() then return false end
    local pend = st.wall_pend
    if pend then
        st.wall_pend = nil
        if t - pend.t <= T.PEND_S and type(ctx.avoid) == "function" then
            place_wall(pend, ctx)
            st.pos = nil
            return true
        end
    end
    local me = R.me()
    local blocked = T.path_blocked(me)
    if (blocked == "left" or blocked == "right") and type(ctx.avoid) == "function" and t - st.snag_t >= T.SNAG_GAP then
        -- front clear, no progress, a corner at the side: a small zone on it
        st.snag_t = t
        local f = facing(me) or 0
        local sx, sy = off(x, y, f, blocked == "right" and 1.5708 or -1.5708, 0.9)
        sx, sy = off(sx, sy, f, 0, 0.5)
        T.stats.snags = T.stats.snags + 1
        R.trail("trace", "snagged on the %s, no progress %.1f s - avoidance zone %.1f yd, re-plan", blocked, t - st.pos_t, T.SNAG_R)
        pcall(ctx.avoid, { x = sx, y = sy, z = z }, T.SNAG_R, "corner at the " .. blocked .. " (ray)")
        st.pos = nil
        return true
    end
    if blocked ~= "front" then return false end
    local h = T.obstacle_height(me)
    if h == nil then return false end
    local hop, why = true, nil
    if h >= T.JUMP_MIN and h <= T.JUMP_MAX then
        hop, why = T.jump_ok(me, h)
        if hop == nil then return false end
    end
    if hop and h >= T.JUMP_MIN and h <= T.JUMP_MAX then
        if ctx.no_jump or ctx.riding or ctx.mounted_flying or t - st.jump_t < T.JUMP_GAP then return false end
        st.jump_t = t
        T.stats.jumps = T.stats.jumps + 1
        R.trail("trace", "an obstacle %.1f yd high ahead, no progress %.1f s - jump", h, t - st.pos_t)
        if type(ctx.jump) == "function" then pcall(ctx.jump) end
        st.pos = nil
        return true
    end
    if (h > T.JUMP_MAX or (not hop and h >= T.JUMP_MIN)) and t - st.wall_t >= T.WALL_GAP and type(ctx.avoid) == "function" then
        st.wall_t = t
        -- measured on the next look (gap_counts needs a fresh ray budget)
        st.wall_pend = { x = x, y = y, z = z, f = facing(me) or 0, h = body(me), hgt = h, why = why, t = t }
        R.trail("trace", "a wall %.1f yd high ahead, no progress %.1f s - measuring its sides", h, t - st.pos_t)
        return false
    end
    return false
end

function T.reset()
    st.pos, st.look_t, st.jump_t, st.wall_t, st.snag_t, st.wall_pend = nil, -1e9, -1e9, -1e9, -1e9, nil
    st.door_t = -1e9
end

return T
