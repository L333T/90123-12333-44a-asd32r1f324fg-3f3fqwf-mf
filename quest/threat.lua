-- ============================================================================
-- restedXP_questing
-- quest/threat.lua - mobs whose aggro range the walk is about to cross
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.16.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.7.0 (user): "preemptively attack enemy targets that the player's path will
-- be moving into the threat path of, UNLESS the enemy is >= 3 levels above the
-- player OR elite - then avoid walking into its threat range".
--
-- THE PATH AHEAD: Sentinel's own path (movement.path_points from the current
-- waypoint, movement.path_index), from the player's position, LOOKAHEAD yd of
-- it. Only while a travel walk runs (not combat / NPC approach walks), out of
-- combat, not on a flight.
--
-- THREAT RANGE: a hostile (red, is_enemy_with) living mob's aggro radius, the
-- classic rule: AGGRO_BASE yd at the player's level, one yard more per level
-- the mob is above the player and one less per level below, AGGRO_MIN..
-- AGGRO_MAX. The walk crosses it when a path segment comes within the radius
-- (2D, and within DZ yd of height).
--
-- WHAT IS DONE (one mob at a time, the first crossing along the path):
--   * DANGEROUS - level >= player + DANGER_LEVELS, or elite / rare elite /
--     world boss (get_classification 1 / 2 / 3): AVOID. 4.9.0: first a
--     Sentinel avoidance zone of its aggro range (+ DETOUR_PAD) at the mob and a
--     soft re-path (movement.avoid_area) - Sentinel plans the whole walk round
--     it. Only when no zone can be made, or the path still crosses the mob
--     ZONE_GRACE s later, the 4.7.0 fallback: a detour point is put
--     outside its circle (the path's closest point pushed out to radius +
--     DETOUR_PAD) and walked first; then the normal walk re-plans from there
--     (and is checked again). At most DETOUR_MAX detours per mob in
--     DETOUR_WINDOW s, then it is let be (logged). A mob whose circle holds the
--     walk's destination is not avoided (it cannot be) - logged once.
--   * Otherwise: ATTACK it first, before the walk carries the player into it -
--     when it is within ATTACK_RANGE yd, attackable, not tapped by someone
--     else and not already fighting someone else.
-- Public: T.check(player) -> nil | "attack", unit, why | "avoid", pos, why;
-- T.aggro_radius(my_level, mob_level); T._reset().
-- ============================================================================

local T = {}

T.LOOKAHEAD = 60        -- yd of the path ahead checked
T.AGGRO_BASE = 20       -- yd aggro radius at the player's level
T.AGGRO_MIN = 5
T.AGGRO_MAX = 45
T.DZ = 12               -- yd of height between the path and the mob
T.DANGER_LEVELS = 3     -- this many levels above the player: avoid
T.ATTACK_RANGE = 40     -- yd: a preemptive pull only this close
T.DETOUR_PAD = 6        -- yd outside the circle
T.DETOUR_MAX = 4
T.DETOUR_WINDOW = 60
T.DETOUR_ARRIVE = 4     -- yd: the detour point is reached
T.DETOUR_TIMEOUT = 15   -- s a detour is walked at most
T.GAP = 0.25            -- s between two checks
T.SCAN = 60             -- yd: mobs looked at
T.ZONE_GRACE = 4.0      -- 4.9.0: s a Sentinel re-path round a zoned mob gets before the detour

local DANGER_CLASS = { [1] = true, [2] = true, [3] = true }

local st = { t = -1e9, res = nil, detour = nil, counts = {}, said = {}, zoned = {} }

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local t = ok and type(izi) == "table" and safe(function() return izi.now() end) or nil
    return type(t) == "number" and t or 0
end

local function trail(fmt, ...)
    local el = package.loaded["errorlog"]
    if type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "threat", fmt, ...) end
end

local function mov() return package.loaded["movement"] end

function T.aggro_radius(my_level, mob_level)
    local r = T.AGGRO_BASE + ((mob_level or my_level) - my_level)
    if r < T.AGGRO_MIN then r = T.AGGRO_MIN elseif r > T.AGGRO_MAX then r = T.AGGRO_MAX end
    return r
end

local function xyz(p)
    if type(p) ~= "table" and type(p) ~= "userdata" then return nil end
    local x, y, z = safe(function() return p.x end), safe(function() return p.y end), safe(function() return p.z end)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y, (type(z) == "number" and z or 0)
end

--- Closest point of segment a-b to m (2D), its height, and the distance.
local function closest(ax, ay, az, bx, by, bz, mx, my)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local f = 0
    if l2 > 1e-6 then
        f = ((mx - ax) * dx + (my - ay) * dy) / l2
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
    end
    local cx, cy, cz = ax + f * dx, ay + f * dy, az + f * (bz - az)
    return cx, cy, cz, math.sqrt((cx - mx) ^ 2 + (cy - my) ^ 2), dx, dy
end

--- The path ahead as a list of {x, y, z}, from the player, LOOKAHEAD yd long.
local function path_ahead(me)
    local m = mov()
    if not m or type(m.path_points) ~= "function" then return nil end
    local pts = m.path_points()
    if type(pts) ~= "table" or #pts == 0 then return nil end
    local i = type(m.path_index) == "function" and m.path_index() or 1
    i = (type(i) == "number" and i >= 1) and math.floor(i) or 1
    local out = { { me.x, me.y, me.z } }
    local len = 0
    for k = i, #pts do
        local x, y, z = xyz(pts[k])
        if x then
            local p = out[#out]
            len = len + math.sqrt((x - p[1]) ^ 2 + (y - p[2]) ^ 2)
            out[#out + 1] = { x, y, z }
            if len >= T.LOOKAHEAD then break end
        end
    end
    return out, pts[#pts]
end

local function hostile_mobs(player, me)
    local list = safe(function() return core.object_manager.get_visible_objects() end)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true and safe(function() return u:is_dead() end) ~= true
            and safe(function() return u:is_enemy_with(player) end) == true then
            local x, y, z = xyz(safe(function() return u:get_position() end))
            if x and (x - me.x) ^ 2 + (y - me.y) ^ 2 <= T.SCAN * T.SCAN then
                out[#out + 1] = { u = u, x = x, y = y, z = z }
            end
        end
    end
    return out
end

local function walking_travel()
    local m = mov()
    if not m then return false end
    local busy = type(m.sentinel_active) == "function" and m.sentinel_active() == true
    if not busy then return false end
    local mode = type(m.nav_mode) == "function" and m.nav_mode() or nil
    return mode ~= "combat" and mode ~= "npc"
end

--- The first mob along the path ahead whose aggro circle the path crosses.
local function first_crossing(player, me, path, dest)
    local my_lvl = safe(function() return player:get_level() end) or 1
    local mobs = hostile_mobs(player, me)
    local best, best_at = nil, nil
    for j = 1, #mobs do
        local mb = mobs[j]
        local lvl = safe(function() return mb.u:get_level() end) or my_lvl
        local r = T.aggro_radius(my_lvl, lvl)
        local along = 0
        for k = 1, #path - 1 do
            local a, b = path[k], path[k + 1]
            local cx, cy, cz, d = closest(a[1], a[2], a[3], b[1], b[2], b[3], mb.x, mb.y)
            if d <= r and math.abs(cz - mb.z) <= T.DZ then
                local at = along + math.sqrt((cx - a[1]) ^ 2 + (cy - a[2]) ^ 2)
                if not best_at or at < best_at then
                    best, best_at = { mob = mb, r = r, lvl = lvl, c = { cx, cy, cz }, seg = { a, b }, d = d }, at
                end
                break
            end
            along = along + math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        end
    end
    if best then
        best.my_lvl = my_lvl
        local dx, dy = xyz(dest)
        best.dest_inside = dx ~= nil and (dx - best.mob.x) ^ 2 + (dy - best.mob.y) ^ 2 <= best.r * best.r
    end
    return best
end

local function dangerous(u, lvl, my_lvl)
    if lvl >= my_lvl + T.DANGER_LEVELS then return "level " .. lvl .. " (you " .. my_lvl .. ")" end
    local c = safe(function() return u:get_classification() end)
    if DANGER_CLASS[c] then return "elite" end
    return nil
end

local function detour_point(hit)
    local mx, my = hit.mob.x, hit.mob.y
    local vx, vy = hit.c[1] - mx, hit.c[2] - my
    local l = math.sqrt(vx * vx + vy * vy)
    if l < 0.5 then                                   -- the path runs over the mob: go round its side
        local a, b = hit.seg[1], hit.seg[2]
        vx, vy = -(b[2] - a[2]), b[1] - a[1]
        l = math.sqrt(vx * vx + vy * vy)
        if l < 1e-6 then vx, vy, l = 1, 0, 1 end
    end
    local out = hit.r + T.DETOUR_PAD
    return { x = mx + vx / l * out, y = my + vy / l * out, z = hit.c[3] }
end

local function name(u) return tostring(safe(function() return u:get_name() end)) end
local function guid(u) return safe(function() return u:get_guid() end) end

--- nil, or "attack", unit, why, or "avoid", pos, why.
function T.check(player)
    if not player then return nil end
    local t = now()
    -- a detour under way: keep walking it until there (or its time is up)
    local dt = st.detour
    if dt then
        local me = safe(function() return player:get_position() end)
        local mx, my = xyz(me)
        if safe(function() return player:is_in_combat() end) == true or (t - dt.t) > T.DETOUR_TIMEOUT
            or (mx and (mx - dt.pos.x) ^ 2 + (my - dt.pos.y) ^ 2 <= T.DETOUR_ARRIVE * T.DETOUR_ARRIVE) then
            st.detour = nil
        else
            return "avoid", dt.pos, dt.why
        end
    end
    if (t - st.t) < T.GAP then
        local r = st.res
        if r then return r[1], r[2], r[3] end
        return nil
    end
    st.t, st.res = t, nil
    if safe(function() return player:is_in_combat() end) == true then return nil end
    if safe(function() return player:is_flying() end) == true then return nil end
    if not walking_travel() then return nil end
    local mx, my, mz = xyz(safe(function() return player:get_position() end))
    if not mx then return nil end
    local me = { x = mx, y = my, z = mz }
    local path, dest = path_ahead(me)
    if not path or #path < 2 then return nil end
    local hit = first_crossing(player, me, path, dest)
    if not hit then return nil end
    local u = hit.mob.u
    local g = guid(u) or "?"
    local danger = dangerous(u, hit.lvl, hit.my_lvl)
    if danger then
        if hit.dest_inside then
            if not st.said[g] then
                st.said[g] = true
                trail("%s (%s) stands at the destination - it cannot be avoided", name(u), danger)
            end
            return nil
        end
        -- 4.9.0: a SENTINEL AVOIDANCE ZONE first - the size of its aggro range
        -- (+ DETOUR_PAD) at the mob, and a soft re-path: Sentinel plans the
        -- whole walk round it, no stop. ZONE_GRACE s for the new path; still
        -- crossing it after that (or no zone possible): the detour below.
        local zwhy = string.format("%s (%s), aggro %.0f yd", name(u), danger, hit.r)
        local zt = st.zoned[g]
        if not zt then
            local mv = mov()
            if mv and type(mv.avoid_area) == "function"
                and mv.avoid_area({ x = hit.mob.x, y = hit.mob.y, z = hit.mob.z }, hit.r + T.DETOUR_PAD, zwhy) then
                st.zoned[g] = t
                trail("avoid %s: Sentinel avoidance zone %.0f yd, path re-planned round it", zwhy, hit.r + T.DETOUR_PAD)
                return nil
            end
        elseif (t - zt) < T.ZONE_GRACE then
            return nil
        end
        local c = st.counts[g]
        if not c or (t - c.t) > T.DETOUR_WINDOW then c = { n = 0, t = t } st.counts[g] = c end
        if c.n >= T.DETOUR_MAX then
            if not st.said[g] then
                st.said[g] = true
                trail("%s (%s): %d detours and the path still crosses it - walking on", name(u), danger, c.n)
            end
            return nil
        end
        c.n = c.n + 1
        local pos = detour_point(hit)
        local why = string.format("%s (%s), aggro %.0f yd", name(u), danger, hit.r)
        st.detour = { pos = pos, t = t, why = why }
        trail("avoid %s: detour to (%.0f, %.0f)", why, pos.x, pos.y)
        st.res = { "avoid", pos, why }
        return "avoid", pos, why
    end
    -- attack it before walking into it
    local d = math.sqrt((hit.mob.x - mx) ^ 2 + (hit.mob.y - my) ^ 2)
    if d > T.ATTACK_RANGE then return nil end
    if safe(function() return player:can_attack(u) end) == false then return nil end
    if safe(function() return u:is_tap_denied() end) == true then return nil end
    if safe(function() return u:is_in_combat() end) == true then
        local tt = safe(function() return u:get_target() end)
        local mg = guid(player)
        if tt and guid(tt) ~= mg then return nil end          -- fighting someone else
    end
    local why = string.format("%s (level %d) - the path crosses its %.0f yd aggro range", name(u), hit.lvl, hit.r)
    st.res = { "attack", u, why }
    return "attack", u, why
end

function T._state() return st end
function T._reset() st.t, st.res, st.detour, st.counts, st.said, st.zoned = -1e9, nil, nil, {}, {}, {} end

return T
