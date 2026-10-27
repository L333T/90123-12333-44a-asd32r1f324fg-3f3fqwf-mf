-- ============================================================================
-- Master Farmer - restedXP Questing (Sentinel)
-- movement/astar.lua - local A* fallback for off-mesh targets
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: restedXP_questing
-- ============================================================================
-- 1.30.0 (user, 2026-10-25: "build the A* as an opt-in local fallback (off by
-- default, kill switch) for off-mesh targets within about 15 yd, with a trace
-- budget per frame, walked through Sentinel"). Reworked from the Orca-style
-- grid search in Desktop\Astar\astar.lua.
--
-- THE ONE RAYCAST EXCEPTION besides game line of sight: nothing here runs
-- unless AS.ON (code kill switch) AND the General tab box "Local A* Fallback"
-- (mfg_astar, on by default) are both on. AS.ERRORS ray / height call errors
-- switch it off for the session (logged); so does a failed self-check.
--
-- WHEN: movement/nav asks AS.start(goal) when Sentinel cannot reach a point -
-- a walk that ended "arrived" short of it (the navmesh ends there) or
-- "unreachable" - and the point is within AS.MAX_YD of the player, out of
-- combat, not swimming, not mounted on a flight.
--
-- THE SEARCH: a 1 yd grid around the player (integer cells, never farther than
-- AS.BOUND_YD from the start), octile-distance A* with a binary heap. A cell:
--   * floor: core.get_height_for_position from just above the parent's height
--     (a 0 answer is a miss - the API cannot tell 0 from no hit);
--   * step: at most AS.STEP_UP yd of height per yd walked (no cliffs, no walls);
--   * clearance: rays parent -> cell at knee and chest height, two more at the
--     knee AS.HALF_W yd to each side (body width), one up at the cell (head);
--     WMO + doodad collision only - terrain is the step rule's job.
-- At most AS.BUDGET rays a frame (a height query counts as one); the search
-- gives up after AS.MAX_NODES cells or AS.MAX_S s.
-- SELF-CHECK: the first job casts one ray down through the ground under the
-- player; it must hit (true = hit). If not, the ray answers are not what this
-- code assumes and the fallback stays off for the session. AS.start only queues
-- the job (it may be called from a Sentinel callback); every game call - the
-- self-check, the rays, the height queries - is made in AS.tick, on the update.
--
-- 2026-10-26 (user: "Add traceline and raycast logic using logic from this example
-- or similar" - the Orca A* port): a height query that misses (0) is answered by a
-- ray snap down instead (the port's Handler:expand hit_z), and the found path is
-- string-pulled (the port's FixPath, done as line of sight): from each kept cell,
-- the farthest later path cell in a straight line whose every crossed grid cell
-- was already found walkable, with no step over STEP_UP, and knee + chest rays
-- clear - a few straight legs instead of a staircase of grid corners. At most
-- AS.PULL_RAYS rays; past that (or on a ray error) the corners are walked as before.
--
-- THE WALK: the grid path is cut to its corners, then walked leg by leg
-- through Sentinel (nav's AS.leg_fn -> move_direct, a single waypoint - never a
-- product key press), one leg start a second at most (nav START_GAP). A leg
-- longer than AS.LEG_S s, or the whole walk past AS.WALK_S s, fails it.
-- ============================================================================

local R = require("movement/core")

local AS = {}

AS.ON = true                    -- KILL SWITCH: false = never runs, whatever the GUI box
AS.enabled_fn = nil             -- set by movement.lua: the GUI box (off by default)
AS.leg_fn = nil                 -- set by movement/nav: function(x, y, z) -> sent?
AS.MAX_YD = 15                  -- an off-mesh target this close (from the player)
AS.BOUND_YD = 20                -- no cell farther than this from the start
AS.STEP = 1.0                   -- yd per grid cell
AS.BUDGET = 40                  -- rays (and height queries) per frame (1.32.1: was 120 - a long stutter at off-mesh NPCs)
AS.MAX_NODES = 600              -- cells expanded per search
AS.MAX_S = 4.0                  -- s per search
AS.STEP_UP = 0.6                -- yd of height per yd walked
AS.KNEE, AS.CHEST, AS.HEAD = 0.9, 1.8, 2.2
AS.HALF_W = 0.35                -- yd: half the body width (side rays)
AS.GOAL_YD, AS.GOAL_DZ = 1.5, 3.0
AS.REACH_YD = 1.2               -- a leg point this close is reached
AS.LEG_S, AS.WALK_S = 6.0, 25.0
AS.ERRORS = 3                   -- ray / height errors -> off for the session
AS.RETRY_S = 60                 -- a goal the search failed is not searched again for this long
AS.PULL_SPAN = 12               -- path cells looked ahead for a straight leg
AS.PULL_RAYS = 20               -- rays the string pulling may cast
AS.SNAP_STEPS = 8               -- binary-search steps of the floor ray snap

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local SQRT2 = math.sqrt(2)

local st = { off = false, why = nil, errors = 0, checked = false, failed = {} }
AS._st = st
local job = nil                  -- the running search
local walk = nil                 -- the running walk
AS.stats = { searches = 0, found = 0, rays = 0, walks = 0, arrived = 0 }

-- ----------------------------------------------------------------------------
-- the game calls (counted, guarded)
-- ----------------------------------------------------------------------------
local vec3_mod = nil
local function v3(x, y, z)
    if vec3_mod == nil then
        local ok, m = pcall(require, "common/geometry/vector_3")
        vec3_mod = (ok and type(m) == "table") and m or false
    end
    if vec3_mod then return vec3_mod.new(x, y, z) end
    return { x = x, y = y, z = z }
end

local flags = nil                -- { block, ground }
local function mask()
    if flags == nil then
        local ok_e, enums = pcall(require, "common/enums")
        local cf = ok_e and type(enums) == "table" and enums.collision_flags or nil
        local ok1, block = pcall(function() return cf.combine("DoodadCollision", "WmoCollision") end)
        local ok2, ground = pcall(function() return cf.combine("DoodadCollision", "WmoCollision", "Terrain") end)
        flags = (ok1 and ok2 and type(block) == "number" and type(ground) == "number")
            and { block = block, ground = ground } or false
    end
    return flags or nil
end

local function turn_off(why)
    if st.off then return end
    st.off, st.why = true, why
    local cb = (job and job.cb) or (walk and walk.cb)
    job, walk = nil, nil
    if type(cb) == "function" then pcall(cb, false, "A* off: " .. tostring(why)) end
    R.log("A* fallback switched off for this session: " .. tostring(why))
    R.trail("astar", "switched off: %s", tostring(why))
end

local function error_seen(what)
    st.errors = st.errors + 1
    R.trail("astar", "%s call failed (%d of %d)", what, st.errors, AS.ERRORS)
    if st.errors >= AS.ERRORS then turn_off(what .. " calls fail") end
end

--- One ray; true = something in the way. nil on an error.
local function ray(ax, ay, az, bx, by, bz, which)
    local f = mask()
    if not f then turn_off("no collision flags") return nil end
    if job then job.rays, job.frame = job.rays + 1, job.frame + 1 end
    AS.stats.rays = AS.stats.rays + 1
    local ok, hit = pcall(core.graphics.trace_line, v3(ax, ay, az), v3(bx, by, bz), f[which or "block"])
    if not ok then error_seen("trace_line") return nil end
    return hit == true
end

--- The floor by a ray straight down from `top` to `bottom` (a binary search on the
--- hit height - trace_line only says hit or not); nil when nothing / an error.
local function snap_floor(x, y, top, bottom)
    local first = ray(x, y, top, x, y, bottom, "ground")
    if not first then return nil end
    local lo, hi = bottom, top
    for _ = 1, AS.SNAP_STEPS do
        local mid = (lo + hi) * 0.5
        local r = ray(x, y, top, x, y, mid, "ground")
        if r == nil then return nil end
        if r then lo = mid else hi = mid end
    end
    return lo
end
AS._snap_floor = snap_floor

--- The floor under (x, y) from just above `from_z`; nil on a miss or an error. A
--- height query miss (0) is tried again with a ray snap (2026-10-26).
local function floor_at(x, y, from_z)
    if job then job.rays, job.frame = job.rays + 1, job.frame + 1 end
    local up = AS.STEP_UP * 2 + 0.5
    local ok, h = pcall(core.get_height_for_position, v3(x, y, from_z), { probe_up = up })
    if not ok then error_seen("get_height_for_position") return nil end
    if type(h) ~= "number" or h ~= h or h == 0 then
        if st.off then return nil end
        return snap_floor(x, y, from_z + up, from_z - 4)
    end
    return h
end

-- ----------------------------------------------------------------------------
-- usable?
-- ----------------------------------------------------------------------------
function AS.enabled()
    if not AS.ON or st.off then return false end
    if type(AS.enabled_fn) ~= "function" then return false end
    local ok, v = pcall(AS.enabled_fn)
    return ok and v == true
end

local function key_of(x, y) return string.format("%d:%d", math.floor(x / 2 + 0.5), math.floor(y / 2 + 0.5)) end

--- 1.30.0: the self-check - a ray down through the ground under the player must hit.
local function self_check(px, py, pz)
    if st.checked then return true end
    local hit = ray(px, py, pz + 1.5, px, py, pz - 2.0, "ground")
    if hit == nil then return false end
    if hit ~= true then
        turn_off("self-check: a ray through the ground under the player did not hit")
        return false
    end
    st.checked = true
    R.trail("astar", "self-check passed (trace_line true = hit)")
    return true
end

-- ----------------------------------------------------------------------------
-- the heap (f, then insertion order)
-- ----------------------------------------------------------------------------
local function heap_push(h, n)
    h[#h + 1] = n
    local i = #h
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].f <= h[i].f then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end

local function heap_pop(h)
    local top = h[1]
    if not top then return nil end
    local last = h[#h]
    h[#h] = nil
    if #h > 0 then
        h[1] = last
        local i = 1
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if h[l] and h[l].f < h[m].f then m = l end
            if h[r] and h[r].f < h[m].f then m = r end
            if m == i then break end
            h[m], h[i] = h[i], h[m]
            i = m
        end
    end
    return top
end
AS._heap_push, AS._heap_pop = heap_push, heap_pop

-- ----------------------------------------------------------------------------
-- the search
-- ----------------------------------------------------------------------------
local function octile(dx, dy)
    dx, dy = math.abs(dx), math.abs(dy)
    return math.max(dx, dy) + (SQRT2 - 1) * math.min(dx, dy)
end

local function cell_id(gx, gy) return gx * 4096 + gy end

local function heuristic(j, x, y, z)
    return octile(j.gx - x, j.gy - y) + math.abs(j.gz - z) * 0.25
end

--- Can the player walk from node `a` to the cell (x, y, z)? nil = an error.
local function passable(a, x, y, z, len)
    if math.abs(z - a.z) > AS.STEP_UP * len then return false end
    local ux, uy = (x - a.x) / len, (y - a.y) / len
    local sx, sy = -uy * AS.HALF_W, ux * AS.HALF_W
    local checks = {
        { a.x, a.y, a.z + AS.KNEE, x, y, z + AS.KNEE },
        { a.x, a.y, a.z + AS.CHEST, x, y, z + AS.CHEST },
        { a.x + sx, a.y + sy, a.z + AS.KNEE, x + sx, y + sy, z + AS.KNEE },
        { a.x - sx, a.y - sy, a.z + AS.KNEE, x - sx, y - sy, z + AS.KNEE },
        { x, y, z + 0.2, x, y, z + AS.HEAD },
    }
    for i = 1, #checks do
        local c = checks[i]
        local hit = ray(c[1], c[2], c[3], c[4], c[5], c[6], "block")
        if hit == nil then return nil end
        if hit then return false end
    end
    return true
end

--- Grid path -> its corners (collinear cells dropped), the goal appended.
local function corners(nodes, gx, gy, gz)
    local out = {}
    for i = 1, #nodes do
        local n, p, q = nodes[i], nodes[i - 1], nodes[i + 1]
        local keep = (i == #nodes)
        if not keep and p and q then
            keep = (n.cx - p.cx) ~= (q.cx - n.cx) or (n.cy - p.cy) ~= (q.cy - n.cy)
        end
        if keep and i > 1 then out[#out + 1] = { x = n.x, y = n.y, z = n.z } end
    end
    local last = out[#out]
    if not last or R.dist3(last.x, last.y, last.z, gx, gy, gz) > 0.5 then
        out[#out + 1] = { x = gx, y = gy, z = gz }
    end
    return out
end
AS._corners = corners

--- Is the straight line from path cell `a` to `b` over cells already found walkable
--- (j.zs), with no step over STEP_UP between two of them?
local function line_known(j, a, b)
    local dx, dy = b.cx - a.cx, b.cy - a.cy
    local n = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) * 2))
    local pid, pz = cell_id(a.cx, a.cy), a.z
    for s = 1, n do
        local cx = math.floor(a.cx + dx * s / n + 0.5)
        local cy = math.floor(a.cy + dy * s / n + 0.5)
        local id = cell_id(cx, cy)
        if id ~= pid then
            local z = j.zs[id]
            if not z or math.abs(z - pz) > AS.STEP_UP * SQRT2 * AS.STEP then return false end
            pid, pz = id, z
        end
    end
    return true
end

--- The grid path string-pulled to straight legs (see the header); nil = use corners().
local function pulled(j, nodes)
    local out, i, n, rays = {}, 1, #nodes, 0
    while i < n do
        local a, best = nodes[i], i + 1
        for k = math.min(n, i + AS.PULL_SPAN), i + 2, -1 do
            local b = nodes[k]
            if line_known(j, a, b) then
                if rays + 2 > AS.PULL_RAYS then return nil end
                rays = rays + 2
                local r1 = ray(a.x, a.y, a.z + AS.KNEE, b.x, b.y, b.z + AS.KNEE, "block")
                if r1 == nil then return nil end
                if not r1 then
                    local r2 = ray(a.x, a.y, a.z + AS.CHEST, b.x, b.y, b.z + AS.CHEST, "block")
                    if r2 == nil then return nil end
                    if not r2 then best = k break end
                end
            end
        end
        local c = nodes[best]
        out[#out + 1] = { x = c.x, y = c.y, z = c.z }
        i = best
    end
    local last = out[#out]
    if not last or R.dist3(last.x, last.y, last.z, j.gx, j.gy, j.gz) > 0.5 then
        out[#out + 1] = { x = j.gx, y = j.gy, z = j.gz }
    end
    return out
end
AS._pulled, AS._line_known = pulled, line_known

local function finish_search(found)
    local j = job
    job = nil
    local ms = (R.now() - j.t0) * 1000
    if not found then
        st.failed[j.key] = R.now()
        R.trail("astar", "no local path to (%.0f, %.0f, %.0f): %d cells, %d rays, %.0f ms - %s", j.gx, j.gy, j.gz,
            j.expanded, j.rays, ms, j.why or "searched out")
        if type(j.cb) == "function" then pcall(j.cb, false, j.why or "no local path") end
        return
    end
    local nodes, n = {}, found
    while n do
        table.insert(nodes, 1, n)
        n = n.parent
    end
    local pts = pulled(j, nodes)
    if st.off then return end
    pts = pts or corners(nodes, j.gx, j.gy, j.gz)
    AS.stats.found = AS.stats.found + 1
    R.trail("astar", "local path to (%.0f, %.0f, %.0f): %d cells -> %d legs, %d rays, %.0f ms", j.gx, j.gy, j.gz,
        #nodes, #pts, j.rays, ms)
    walk = { pts = pts, i = 1, t0 = R.now(), leg_t = -1e9, sent_i = 0, key = j.key, cb = j.cb,
        goal = { x = j.gx, y = j.gy, z = j.gz } }
    AS.stats.walks = AS.stats.walks + 1
end

--- One budgeted slice of the search.
local function search_slice(t)
    local j = job
    j.frame = 0
    -- the self-check runs here, on the update tick (AS.start may be called from a Sentinel callback)
    if not st.checked then
        if not self_check(j.sx, j.sy, j.sz) then
            if job == j then j.why = "self-check" return finish_search(nil) end
            return
        end
    end
    if t - j.t0 > AS.MAX_S then j.why = "out of time" return finish_search(nil) end
    while job == j and j.frame < AS.BUDGET do
        local cur = j.cur
        if not cur or j.di > #DIRS then
            -- the next cell to expand
            repeat cur = heap_pop(j.open) until cur == nil or not j.closed[cur.id]
            if not cur then j.why = "no open cells left" return finish_search(nil) end
            j.closed[cur.id] = true
            j.expanded = j.expanded + 1
            if j.expanded > AS.MAX_NODES then j.why = "cell limit" return finish_search(nil) end
            if R.dist3(cur.x, cur.y, 0, j.gx, j.gy, 0) <= AS.GOAL_YD and math.abs(cur.z - j.gz) <= AS.GOAL_DZ then
                return finish_search(cur)
            end
            j.cur, j.di = cur, 1
        end
        local d = DIRS[j.di]
        j.di = j.di + 1
        local cx, cy = cur.cx + d[1], cur.cy + d[2]
        local id = cell_id(cx, cy)
        local x, y = j.sx + cx * AS.STEP, j.sy + cy * AS.STEP
        if not j.closed[id] and R.dist3(x, y, 0, j.sx, j.sy, 0) <= AS.BOUND_YD then
            local len = (d[1] ~= 0 and d[2] ~= 0) and SQRT2 * AS.STEP or AS.STEP
            local g = cur.g + len
            local known = j.best[id]
            if not known or g < known then
                local z = floor_at(x, y, cur.z)
                if st.off then return end
                if z then
                    local ok = passable(cur, x, y, z, len)
                    if st.off then return end
                    if ok then
                        g = g + math.abs(z - cur.z) * 0.5
                        j.best[id] = g
                        j.zs[id] = z                 -- 2026-10-26: walkable, for the string pulling
                        heap_push(j.open, { id = id, cx = cx, cy = cy, x = x, y = y, z = z, g = g,
                            f = g + heuristic(j, x, y, z), parent = cur })
                    else
                        j.closed[id] = true          -- a wall / cliff from this side: not again
                    end
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- the walk
-- ----------------------------------------------------------------------------
local function end_walk(ok, why)
    local w = walk
    walk = nil
    if ok then
        AS.stats.arrived = AS.stats.arrived + 1
        st.failed[w.key] = nil
    else
        st.failed[w.key] = R.now()
    end
    R.trail("astar", "local walk %s%s", ok and "arrived" or "failed", why and (": " .. why) or "")
    if type(w.cb) == "function" then pcall(w.cb, ok, why) end
end

local function walk_slice(t)
    local w = walk
    local px, py, pz = R.here()
    if not px then return end
    if t - w.t0 > AS.WALK_S then return end_walk(false, "took too long") end
    local p = w.pts[w.i]
    while p and R.dist3(px, py, 0, p.x, p.y, 0) <= AS.REACH_YD do
        w.i = w.i + 1
        p = w.pts[w.i]
    end
    if not p then return end_walk(true) end
    if w.sent_i == w.i then
        if t - w.leg_t > AS.LEG_S then return end_walk(false, "leg " .. w.i .. " not reached") end
        return
    end
    if type(AS.leg_fn) ~= "function" then return end_walk(false, "no walker") end
    local ok, sent = pcall(AS.leg_fn, p.x, p.y, p.z)
    if ok and sent == true then
        w.sent_i, w.leg_t = w.i, t
    end
end

-- ----------------------------------------------------------------------------
-- surface
-- ----------------------------------------------------------------------------
local function safe_swimming()
    local ok, v = pcall(function() return core.character.is_swimming() end)
    return ok and v == true
end

--- Search a local path to `goal` and walk it. cb(ok, why) at the end. False
--- when the fallback does not apply (off, too far, failed here lately, ...).
function AS.start(goal, cb)
    if not AS.enabled() then return false end
    local gx, gy, gz = R.xyz(goal)
    local px, py, pz = R.here()
    if not gx or not px then return false end
    local d = R.dist3(px, py, 0, gx, gy, 0)
    if d > AS.MAX_YD or d <= AS.GOAL_YD then return false end
    local key = key_of(gx, gy)
    if st.failed[key] and (R.now() - st.failed[key]) < AS.RETRY_S then return false end
    if AS.active() then
        if (job and job.key == key) or (walk and walk.key == key) then return true end
        AS.cancel("a new goal")
    end
    if safe_swimming() then return false end
    job = { key = key, sx = px, sy = py, sz = pz, gx = gx, gy = gy, gz = gz, t0 = R.now(), open = {}, closed = {},
        best = {}, zs = {}, expanded = 0, rays = 0, frame = 0, cur = nil, di = 1, cb = cb }
    local start = { id = cell_id(0, 0), cx = 0, cy = 0, x = px, y = py, z = pz, g = 0 }
    start.f = heuristic(job, px, py, pz)
    job.best[start.id] = 0
    job.zs[start.id] = pz
    heap_push(job.open, start)
    AS.stats.searches = AS.stats.searches + 1
    R.trail("astar", "searching a local path to (%.0f, %.0f, %.0f), %.1f yd (Sentinel cannot reach it)", gx, gy, gz, d)
    return true
end

--- Every frame (movement.pulse): one budgeted slice of the search, or the walk.
function AS.tick(t)
    if not job and not walk then return end
    if not AS.enabled() then return AS.cancel("switched off") end
    t = t or R.now()
    if job then return search_slice(t) end
    if walk then return walk_slice(t) end
end

function AS.active() return job ~= nil or walk ~= nil end
function AS.searching() return job ~= nil end
function AS.walking() return walk ~= nil end
--- The goal of the running search / walk (or nil).
function AS.goal()
    if job then return { x = job.gx, y = job.gy, z = job.gz } end
    if walk then return walk.goal end
    return nil
end
function AS.for_goal(pos)
    local x, y = R.xyz(pos)
    local g = AS.goal()
    return x ~= nil and g ~= nil and R.dist3(x, y, 0, g.x, g.y, 0) <= 2.0
end

function AS.cancel(why)
    if not job and not walk then return end
    R.trail("astar", "cancelled: %s", tostring(why or "?"))
    job, walk = nil, nil
end

function AS.reset()
    job, walk = nil, nil
    st.failed = {}
end

function AS.status()
    if not AS.ON then return "off (kill switch)" end
    if st.off then return "off: " .. tostring(st.why) end
    if not AS.enabled() then return "off (GUI)" end
    if job then return string.format("searching (%d cells, %d rays)", job.expanded, job.rays) end
    if walk then return string.format("walking leg %d of %d", walk.i, #walk.pts) end
    return "ready"
end

return AS
