-- ============================================================================
-- restedXP_questing
-- movement/astar.lua - local path fallback for off-mesh targets
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.46.0
-- ============================================================================
-- 4.46.0 (the Astar movement engine port, group A of
-- docs/ASTAR_ENGINE_PORT_PLAN.md): the 537-line grid search that used to live
-- here is gone. The planning is `engine/astar.lua`'s HPA* planner now
-- (hierarchical: a macro graph of cluster openings over a 1-yard micro grid,
-- weighted for slope, cliffs, wall clearance and remembered stuck disks),
-- asked through engine.plan_only - which plans and hands the point list over
-- WITHOUT walking it.
--
-- WHAT DID NOT CHANGE, on purpose:
--   * the surface. movement/nav.lua and movement.lua see exactly the same
--     AS.* names, so neither needed an edit: AS.start / tick / cancel / reset,
--     AS.active / searching / walking / goal / for_goal / status, AS.leg_fn,
--     AS.enabled_fn, AS.ON, AS.stats and the tuning constants.
--   * the WALK. The point list is still walked leg by leg through AS.leg_fn
--     (nav's move_direct, one off-mesh waypoint, never a key press), one leg
--     start a second at most, AS.LEG_S per leg and AS.WALK_S for the whole
--     walk. nav keeps the walk token - the engine never moves the character
--     here.
--   * the gates. AS.ON (code kill switch) AND the General tab box both have to
--     be on, AND the rays have to be healthy.
--
-- 4.46.0 RAY HEALTH IS NOT THIS FILE'S. movement/trace.lua owns it, and 4.45.0
-- is why: a trace_line that THROWS is a broken client and switches rays off at
-- once, but one that merely ANSWERS FALSE only says that segment hit nothing -
-- expected in the air after a jump, while swimming, on a lift or on a thin WMO
-- edge - so it takes SELF_TRIES trustworthy misses SELF_GAP s apart. A second
-- self-check here would be a second switch, and two switches are what caused
-- the 10-27 mid-match native crash in Auto BG. So this file asks T.ready() /
-- T.enabled() and condemns through T, never on its own.
--   * the failure memory. A goal the planner could not reach is not retried for
--     AS.RETRY_S, and the outcome is still the caller's cb(ok, why).
--
-- WHY THE PLANNER IS WORTH THE SWAP. The old search was a flat 1-yard grid
-- bounded 20 yd from the start, a node table per expanded cell, up to 600 of
-- them, thrown away after every search (measured: 189 KB a search). The engine
-- stores a cluster as flat arrays of numbers - 26.6 bytes a cell, written only
-- where a trace touched - and keeps at most five of them, so it reaches much
-- further for less: docs/ASTAR_ENGINE_PORT_PLAN.md has the measurements.
-- ============================================================================

local R = require("movement/core")
local TR = require("movement/trace")   -- 4.46.0: THE shared ray health lives there

-- The engine is fetched on first use, not at load: a session that never meets
-- an off-mesh target never pays for it, and a test that only loads the travel
-- layer does not have to stub the engine's own modules.
local engine_mod = nil
local function engine()
    if engine_mod == nil then
        local ok, mod = pcall(require, "engine/astar")
        engine_mod = (ok and type(mod) == "table") and mod or false
        if not engine_mod then
            R.trail("astar", "engine/astar did not load - the local fallback is off")
        end
    end
    return engine_mod or nil
end

local AS = {}

AS.ON = true                    -- KILL SWITCH: false = never runs, whatever the GUI box
AS.enabled_fn = nil             -- set by movement.lua: the GUI box
AS.leg_fn = nil                 -- set by movement/nav: function(x, y, z) -> sent?
AS.MAX_YD = 15                  -- an off-mesh target this close (from the player)
AS.GOAL_YD, AS.GOAL_DZ = 1.5, 3.0
AS.REACH_YD = 1.2               -- a leg point this close is reached
AS.LEG_S, AS.WALK_S = 6.0, 25.0
AS.PLAN_S = 4.0                 -- s a plan request may take before it is given up
AS.ERRORS = 3                   -- ray / height errors -> off for the session
AS.RETRY_S = 60                 -- a goal the planner failed is not retried for this long

AS.stats = { searches = 0, found = 0, walks = 0, arrived = 0 }

local st = { off = false, why = nil, errors = 0, checked = false, failed = {} }
AS._st = st

local job = nil                  -- a plan request in flight
local walk = nil                 -- the running walk

local function key_of(x, y)
    return math.floor(x / 4) .. ":" .. math.floor(y / 4)
end

-- ----------------------------------------------------------------------------
-- gates and ray health
-- ----------------------------------------------------------------------------
--- The shared ray health, asked of movement/trace.lua: its own self-check has
--- to have passed and its switch must not be off. Nothing is sampled here.
local function rays_ok()
    if type(TR.ready) == "function" then
        local ok, ready = pcall(TR.ready)
        if ok and ready ~= true then return false end
    end
    if type(TR.enabled) == "function" then
        local ok, on = pcall(TR.enabled)
        if ok and on ~= true then return false end
    end
    return true
end

AS._rays_ok = rays_ok

local function switch_off(why)
    if st.off then return end
    st.off, st.why = true, why
    R.trail("astar", "local path fallback off for this session: %s", tostring(why))
end

AS.switch_off = switch_off

--- A ray or height call that threw is the CLIENT, not this goal, so it is
--- reported to movement/trace.lua and every ray user in this product stops
--- together. This file keeps no switch of its own beyond AS.ON.
function AS.note_error(what)
    st.errors = st.errors + 1
    -- this product's movement/trace.lua keeps its switch private (auto_bg's
    -- exposes T.client_bad); both are honoured, whichever exists
    if type(TR.client_bad) == "function" then
        pcall(TR.client_bad, "astar: " .. tostring(what))
    elseif type(TR.note_error) == "function" then
        pcall(TR.note_error, what)
    end
    if st.errors >= AS.ERRORS then
        switch_off("ray errors (" .. tostring(what) .. ")")
    end
end

function AS.enabled()
    if not AS.ON or st.off then return false end
    if type(AS.enabled_fn) == "function" then
        local ok, on = pcall(AS.enabled_fn)
        if not ok or on ~= true then return false end
    end
    return rays_ok()
end



local function safe_swimming()
    local ok, v = pcall(function() return core.character.is_swimming() end)
    return ok and v == true
end

-- ----------------------------------------------------------------------------
-- the walk (unchanged: nav's move_direct, leg by leg)
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
    local px, py = R.here()
    if not px then return end
    if t - w.t0 > AS.WALK_S then return end_walk(false, "took too long") end
    local p = w.pts[w.i]
    while p and R.dist2(px, py, p.x, p.y) <= AS.REACH_YD do
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
--- Plan a local path to `goal` and walk it. cb(ok, why) at the end. False when
--- the fallback does not apply (off, too far, failed here lately, ...).
function AS.start(goal, cb)
    if not AS.enabled() then return false end
    local gx, gy, gz = R.xyz(goal)
    local px, py = R.here()
    if not gx or not px then return false end
    local d = R.dist2(px, py, gx, gy)
    if d > AS.MAX_YD or d <= AS.GOAL_YD then return false end
    local key = key_of(gx, gy)
    if st.failed[key] and (R.now() - st.failed[key]) < AS.RETRY_S then return false end
    if AS.active() then
        if (job and job.key == key) or (walk and walk.key == key) then return true end
        AS.cancel("a new goal")
    end
    if safe_swimming() then return false end

    job = { key = key, gx = gx, gy = gy, gz = gz, t0 = R.now(), cb = cb }
    AS.stats.searches = AS.stats.searches + 1
    local E = engine()
    if not E then
        job = nil
        return false
    end
    local asked = E.plan_only({ x = gx, y = gy, z = gz }, function(points, why)
        local j = job
        if not j then return end                      -- cancelled meanwhile
        job = nil
        if type(points) ~= "table" or #points < 1 then
            st.failed[j.key] = R.now()
            R.trail("astar", "no local path to (%.0f, %.0f, %.0f): %s", j.gx, j.gy, j.gz,
                tostring(why or "no path"))
            if type(j.cb) == "function" then pcall(j.cb, false, why or "no path") end
            return
        end
        local pts = {}
        for i = 1, #points do
            local p = points[i]
            pts[i] = { x = p.x, y = p.y, z = p.z }
        end
        AS.stats.found = AS.stats.found + 1
        AS.stats.walks = AS.stats.walks + 1
        walk = { pts = pts, i = 1, t0 = R.now(), leg_t = -1e9, sent_i = 0, key = j.key, cb = j.cb }
        R.trail("astar", "local path to (%.0f, %.0f, %.0f): %d legs", j.gx, j.gy, j.gz, #pts)
    end)
    if not asked then
        job = nil
        return false
    end
    R.trail("astar", "planning a local path to (%.0f, %.0f, %.0f), %.1f yd (Sentinel cannot reach it)",
        gx, gy, gz, d)
    return true
end

--- Every frame (movement.pulse). The planner runs on its own update callback
--- and keeps to its own cross-frame budget; this only times a lost answer out
--- and drives the walk.
function AS.tick(t)
    if not job and not walk then return end
    if not AS.enabled() then return AS.cancel("switched off") end
    t = t or R.now()
    if job then
        if (t - job.t0) > AS.PLAN_S then
            local j = job
            job = nil
            local E = engine()
            if E then E.cancel("astar plan timeout") end
            st.failed[j.key] = R.now()
            if type(j.cb) == "function" then pcall(j.cb, false, "plan timed out") end
        end
        return
    end
    if walk then return walk_slice(t) end
end

function AS.active() return job ~= nil or walk ~= nil end
function AS.searching() return job ~= nil end
function AS.walking() return walk ~= nil end

function AS.goal()
    if job then return job.gx, job.gy, job.gz end
    if walk then
        local p = walk.pts[#walk.pts]
        if p then return p.x, p.y, p.z end
    end
    return nil
end

function AS.for_goal(pos)
    local x, y = R.xyz(pos)
    if not x then return false end
    local key = key_of(x, y)
    return (job and job.key == key) or (walk and walk.key == key) or false
end

function AS.cancel(why)
    if job then
        local j = job
        job = nil
        local E = engine()
        if E then E.cancel(why or "cancelled") end
        if type(j.cb) == "function" then pcall(j.cb, false, why or "cancelled") end
    end
    if walk then end_walk(false, why or "cancelled") end
end

function AS.reset()
    job, walk = nil, nil
    st.failed = {}
    st.errors = 0
end

function AS.status()
    if st.off then return "off: " .. tostring(st.why) end
    if not AS.enabled() then return "off" end
    if job then return "planning" end
    if walk then return string.format("walking leg %d of %d", walk.i, #walk.pts) end
    return "idle"
end

return AS
