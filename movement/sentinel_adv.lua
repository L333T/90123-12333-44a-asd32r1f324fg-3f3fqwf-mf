-- ============================================================================
-- Master Farmer - Grindbot
-- movement/sentinel_adv.lua - Sentinel ADVANCED (lower-level) services
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.235.0
-- ============================================================================
-- IF PATHING BREAKS, START HERE.
--
-- Sentinel's documentation lists client.nav_client (NavigationService),
-- client.movement (MovementService) and client.obstacle (ObstacleService) as
-- "lower-level services ... more likely to change than the high-level Client
-- API", and documents only their method NAMES - not argument shapes, return
-- values or callback arguments. Every call made into them from this file is
-- therefore:
--
--   * feature-detected (a missing method = the feature is off, silently);
--   * pcall-guarded, and switched off for the session after MAX_FAILS errors
--     (a "disabled for the session" trail line names it);
--   * shape-logged: the first result of each call is written to the session
--     log ("adv api <name> first result: ..."), so a changed return value is
--     visible in the first log after a Sentinel update;
--   * acted on only for shapes recognised below - anything else is logged and
--     ignored, never guessed at.
--
-- What uses them:
--   1. get_continent_id (static)   continent change -> blacklist zones, Sentinel
--                                  caches and the running walk are reset (zones
--                                  and caches are x / y only; coordinates repeat
--                                  on every continent).
--   2. check_path                  the rest of the running Sentinel path is
--                                  validated every CHECK_GAP s; "invalid" -> one
--                                  replan (gated per destination).
--   3. obstacle:probe_path_ahead   obstacles on the next segments; an explicit
--                                  "blocked" twice in a row -> one replan.
--   4. obstacle:get_zone_count     our blacklist mirror lost from Sentinel's
--                                  obstacle list (server restart) -> pushed again.
--
-- Not used, on purpose: client.movement (navigate / process / strafe) - the
-- client drives its own MovementService, and a second driver fights it;
-- find_route_tsp - the high-level plan_route already plans grind node order;
-- find_route_multi - RestedXP decides quest waypoint order and the engine walks
-- them one at a time; remove_zone / get_avoidance_zones - the index base and the
-- zone shape are undocumented.
--
-- Already used elsewhere (movement/sentinel.lua): find_path, find_path_avoid,
-- find_path_corridor, check_path (recorded routes), raycast, random_point,
-- kite, flee, add_zone, clear. Same caution applies there.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local K = require("movement/const")
local R = require("movement/rt")
local U = require("movement/util")
local Z = require("movement/zones")
local N = require("movement/sentinel")
local O = require("movement/own")

local OWNER = K.OWNER
local here_xyz = U.here_xyz

local Adv = {}

local MAX_FAILS   = 5
local CONT_GAP    = 2.0     -- continent poll
local CHECK_GAP   = 3.0     -- check_path on the running path
local PROBE_GAP   = 1.0     -- probe_path_ahead
local ZONE_GAP    = 10.0    -- zone mirror check
local REPLAN_COOL = 8.0     -- at most one advanced-API replan per this
local DEST_REPLANS = 2      -- per destination; past it the verdicts are only logged
local CHECK_PTS   = 40      -- path points sent to check_path
local PROBE_PTS   = 6       -- path points sent to probe_path_ahead
local PROBE_SEGS  = 3

-- name -> { fails, off, shape }
local api = {
    continent  = { fails = 0, off = false, shape = nil },
    check_path = { fails = 0, off = false, shape = nil },
    probe      = { fails = 0, off = false, shape = nil },
    zone_count = { fails = 0, off = false, shape = nil },
}

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "sentinel", fmt, ...)
    end
end

--- A short description of any value: type, number / boolean value, table keys.
local function describe(v)
    local tv = type(v)
    if tv ~= "table" then return tv .. " " .. tostring(v) end
    local keys, n = {}, 0
    for k, x in pairs(v) do
        n = n + 1
        if n <= 8 then keys[#keys + 1] = tostring(k) .. ":" .. type(x) end
    end
    return string.format("table #%d {%s%s}", #v, table.concat(keys, ", "), n > 8 and ", ..." or "")
end

local function note_shape(name, v)
    local a = api[name]
    if a.shape then return end
    a.shape = describe(v)
    trail("adv api %s first result: %s", name, a.shape)
end

local function failed(name, err)
    local a = api[name]
    a.fails = a.fails + 1
    if a.fails >= MAX_FAILS and not a.off then
        a.off = true
        trail("adv api %s disabled for the session after %d errors: %s", name, a.fails, tostring(err))
    end
end

local function raw_client()
    local S = rawget(_G, "SentinelNavClient")
    local ok, c = pcall(function() return S and S.client end)
    if ok and type(c) == "table" then return c end
    return nil
end

--- A recognised validity verdict: true / false, or nil when the shape is not
--- one this file understands.
local function verdict_valid(v)
    if v == true or v == false then return v end
    if type(v) == "table" then
        for _, k in ipairs({ "valid", "ok", "success", "reachable" }) do
            if v[k] == true or v[k] == false then return v[k] end
        end
        for _, k in ipairs({ "blocked", "invalid" }) do
            if v[k] == true then return false end
            if v[k] == false then return true end
        end
    end
    return nil
end

--- A recognised "blocked" from a probe: true only for an explicit field.
--- A bare boolean is ambiguous (blocked? clear?) and is not acted on.
local function verdict_blocked(v)
    if type(v) ~= "table" then return nil end
    for _, k in ipairs({ "blocked", "hit", "obstructed", "obstacle" }) do
        if v[k] == true then return true end
        if v[k] == false then return false end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- REPLAN GATE (shared by check_path and the probe)
-- ----------------------------------------------------------------------------
local rp = { t = -1e9, key = nil, n = 0, muted_key = nil }

local function dest_key()
    if type(R.dest_x) ~= "number" then return nil end
    return string.format("%d|%d", math.floor(R.dest_x / 4), math.floor(R.dest_y / 4))
end

local function replan(why, detail)
    local t = izi.now()
    if (t - rp.t) < REPLAN_COOL then return false end
    local key = dest_key()
    if key ~= rp.key then rp.key, rp.n = key, 0 end
    if rp.n >= DEST_REPLANS then
        if rp.muted_key ~= key then
            rp.muted_key = key
            trail("adv api: %s again after %d replans to this destination - only logging now", why, rp.n)
        end
        return false
    end
    if N.replan(why) then
        rp.t, rp.n = t, rp.n + 1
        trail("adv api: %s (%s) - replanned", why, tostring(detail))
        return true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- 1. CONTINENT CHANGE
-- ----------------------------------------------------------------------------
local cont = { t = -1e9, id = nil, cand = nil }

local function read_continent()
    local a = api.continent
    if a.off then return nil end
    local c = raw_client()
    local nc = c and c.nav_client
    local fn = type(nc) == "table" and nc.get_continent_id or nil
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn)                   -- documented as static
    if not ok then ok, v = pcall(fn, nc) end  -- ... or a method after all
    if not ok then
        failed("continent", v)
        return nil
    end
    note_shape("continent", v)
    return tonumber(v)
end

local function continent_tick(t)
    if (t - cont.t) < CONT_GAP then return end
    cont.t = t
    local id = read_continent()
    if id == nil then return end              -- loading screen, or no answer
    if cont.id == nil then
        cont.id = id
        return
    end
    if id == cont.id then
        cont.cand = nil
        return
    end
    if cont.cand ~= id then                   -- confirm on the next sample
        cont.cand = id
        return
    end
    trail("continent %s -> %s: blacklist zones, Sentinel caches and the walk reset", tostring(cont.id), tostring(id))
    cont.id, cont.cand = id, nil
    Z.clear_all()
    N.reset_caches()
    rp.key, rp.n, rp.muted_key = nil, 0, nil
    if R.cur_owner ~= OWNER.COMBAT then
        O.halt_all()
    end
end

-- ----------------------------------------------------------------------------
-- RUNNING PATH (shared): the rest of Sentinel's current path, as vec3s
-- ----------------------------------------------------------------------------
local function remaining_path(c, max_pts)
    if type(c.get_current_path) ~= "function" then return nil end
    local okp, path = pcall(c.get_current_path, c)
    if not okp or type(path) ~= "table" or #path < 2 then return nil end
    local idx = 1
    if type(c.get_path_index) == "function" then
        local oki, i = pcall(c.get_path_index, c)
        if oki and type(i) == "number" and i >= 1 then idx = i end
    end
    local out = {}
    local ok = pcall(function()
        for i = idx, #path do
            local p = path[i]
            local x, y, z = p.x, p.y, p.z
            if type(x) == "number" and type(y) == "number" then
                out[#out + 1] = vec3.new(x, y, z or 0)
                if #out >= max_pts then break end
            end
        end
    end)
    if not ok or #out < 2 then return nil end
    return out
end

local function following()
    if not R.sn_active or R.cur_owner == OWNER.COMBAT or R.rest_lock then return false end
    if N.planning() or N.recovering() then return false end
    return type(R.sn_client) == "table"
end

-- ----------------------------------------------------------------------------
-- 2. CHECK THE RUNNING PATH
-- ----------------------------------------------------------------------------
local pc = { asked = -1e9, pending = false }

local function path_check_tick(t)
    local a = api.check_path
    if a.off or not following() then return end
    if pc.pending and (t - pc.asked) < 6 then return end
    if (t - pc.asked) < CHECK_GAP then return end
    local c = R.sn_client
    local nc = c.nav_client
    if type(nc) ~= "table" or type(nc.check_path) ~= "function" then return end
    local pts = remaining_path(c, CHECK_PTS)
    if not pts then return end
    local hx, hy, hz = here_xyz()
    if not hx then return end
    pc.asked, pc.pending = t, true
    local leg = R.sn_issued
    local ok, err = pcall(nc.check_path, nc, vec3.new(hx, hy, hz), pts, function(res)
        pc.pending = false
        note_shape("check_path", res)
        if leg ~= R.sn_issued or not following() then return end   -- another leg now
        if verdict_valid(res) == false then
            replan("path_invalid", "check_path")
        end
    end)
    if not ok then
        pc.pending = false
        failed("check_path", err)
    end
end

-- ----------------------------------------------------------------------------
-- 3. OBSTACLES AHEAD
-- ----------------------------------------------------------------------------
local pb = { t = -1e9, streak = 0, leg = nil }

local function probe_tick(t)
    local a = api.probe
    if a.off or not following() then
        pb.streak = 0
        return
    end
    if (t - pb.t) < PROBE_GAP then return end
    pb.t = t
    local c = R.sn_client
    local ob = c.obstacle
    if type(ob) ~= "table" or type(ob.probe_path_ahead) ~= "function" then return end
    if pb.leg ~= R.sn_issued then pb.leg, pb.streak = R.sn_issued, 0 end
    local pts = remaining_path(c, PROBE_PTS)
    if not pts then return end
    local ok, res = pcall(ob.probe_path_ahead, ob, pts, PROBE_SEGS)
    if not ok then
        failed("probe", res)
        return
    end
    note_shape("probe", res)
    if verdict_blocked(res) == true then
        pb.streak = pb.streak + 1
        if pb.streak >= 2 then
            pb.streak = 0
            replan("obstacle_ahead", "probe_path_ahead")
        end
    else
        pb.streak = 0
    end
end

-- ----------------------------------------------------------------------------
-- 4. ZONE MIRROR
-- ----------------------------------------------------------------------------
local zc = { t = -1e9 }

local function zone_tick(t)
    local a = api.zone_count
    if a.off or (t - zc.t) < ZONE_GAP then return end
    zc.t = t
    local mine = Z.sentinel_count()
    if type(mine) ~= "number" or mine <= 0 then return end
    local c = raw_client()
    local ob = c and c.obstacle
    if type(ob) ~= "table" or type(ob.get_zone_count) ~= "function" then return end
    local ok, n = pcall(ob.get_zone_count, ob)
    if not ok then
        failed("zone_count", n)
        return
    end
    note_shape("zone_count", n)
    n = tonumber(n)
    if n and n < mine then
        trail("adv api: Sentinel holds %d avoidance zone(s), %d pushed - pushing them again", n, mine)
        Z.resync_sentinel()
    end
end

-- ----------------------------------------------------------------------------
-- PER FRAME (fsm.pulse). Each part throttles itself.
-- ----------------------------------------------------------------------------
function Adv.tick(t)
    continent_tick(t)
    zone_tick(t)
    if R.sn_active then
        path_check_tick(t)
        probe_tick(t)
    end
end

--- What each advanced API is doing - for diagnostics.
function Adv.status()
    local out = {}
    for name, a in pairs(api) do
        out[name] = { off = a.off, fails = a.fails, shape = a.shape }
    end
    out.continent_id = cont.id
    return out
end

return Adv
