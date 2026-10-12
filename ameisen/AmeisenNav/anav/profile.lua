-- ============================================================================
-- AmeisenNav
-- anav/profile.lua - movement settings for where the player is right now
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- One set of steering numbers does not fit everywhere. A 6 yd wall probe is
-- right on open ground and hits the far wall of every inn room; 0.8 yd of
-- clearance round an object is comfortable outside and makes a corridor
-- impassable inside; a 2.5 yd waypoint reach is fine on foot and makes a
-- mount orbit its corners.
--
-- PROFILES  (C.profile_mode "auto" picks one; the menu can force one)
--   outdoor   the base values: the plain keys of anav/config.lua
--   indoor    buildings and caves. WoW flags both as indoors (no mounting),
--             so one profile covers them: short probes, tight clearance,
--             short corner cuts, a smaller drop counts as a ledge.
--   swim      in the water: no ground check (the probe answers the lake bed),
--             slower, longer stuck window.
--   A profile only lists what differs from outdoor (C.profiles.<name>).
--
-- ON TOP OF THE PROFILE
--   speed     C.scale_with_speed: reach and look-ahead distances grow with
--             the movement speed over the 7 yd/s run speed (mounted, sprint),
--             capped at C.speed_scale_max. Arrival reach does not scale.
--   combat    units are only obstacles in combat when C.avoid_units_in_combat:
--             in a fight the units around you are the fight.
--   height    the knee and chest rays sit at 25% / 65% of the player's model
--             height (gnome to tauren, mounted), clamped.
--
-- An indoor/outdoor flip has to read the same twice in a row (one second)
-- before the profile changes: doorways flicker.
-- ============================================================================

local C = require("anav/config")
local L = require("anav/log")
local X = require("anav/context")

local P = {}

local RUN_SPEED = 7.0
local EVERY = 0.5

--- Distances that grow with speed.
P.SCALED = {
    waypoint_threshold = true, wall_probe = true, avoid_lookahead = true,
    deviation_limit = true, string_pull_range = true,
}

--- Every key a profile may override, in menu order.
P.KEYS = {
    "waypoint_threshold", "final_threshold", "wall_probe", "avoid_lookahead",
    "avoid_clearance", "string_pull_range", "deviation_limit", "stuck_window",
    "ground_max_dev",
}

--- What the player is doing, refreshed every EVERY seconds.
P.env = {
    profile = "outdoor", indoors = false, swimming = false, mounted = false,
    combat = false, speed = RUN_SPEED, factor = 1.0, height = 2.0,
    knee = 0.5, chest = 1.3, ground = nil, t = 0,
}

local next_read = 0
local pending, pending_n = nil, 0
local last_speed = RUN_SPEED
local last_mode = nil

local function flag(obj, name)
    local ok, v = X.call(obj, name)
    return ok and v == true
end

local function number(obj, name)
    local ok, v = X.call(obj, name)
    if ok and type(v) == "number" and v == v then return v end
    return nil
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

--- The profile the environment asks for, before hysteresis.
local function wanted(env)
    local mode = C.profile_mode
    if mode == "outdoor" or mode == "indoor" or mode == "swim" then return mode end
    if env.swimming then return "swim" end
    if env.indoors then return "indoor" end
    return "outdoor"
end

--- Call once per update tick.
function P.update()
    local t = core.time()
    if t < next_read then return end
    next_read = t + EVERY
    local env = P.env
    env.t = t

    local me = X.player()
    if not me then return end
    env.indoors = flag(me, "is_indoors")
    env.mounted = flag(me, "is_mounted")
    env.combat = flag(me, "is_in_combat")
    local oks, swim = X.call_fn("core.character.is_swimming", core.character and core.character.is_swimming)
    env.swimming = oks and swim == true

    -- speed: the current one while moving, the last moving one while still
    local speed = number(me, "get_movement_speed")
    if speed and speed > 1 then last_speed = speed end
    env.speed = last_speed
    env.factor = C.scale_with_speed and clamp(last_speed / RUN_SPEED, 1.0, C.speed_scale_max) or 1.0

    -- model height -> ray heights
    local h = number(me, "get_height")
    if h and h > 0.3 and h < 10 then env.height = h end
    env.knee = clamp(env.height * 0.25, 0.35, 0.8)
    env.chest = clamp(env.height * 0.65, 0.9, 2.6)

    -- ground under the player (shown in the menu; tells the terrain from a
    -- floor, a bridge or a ledge the player stands on)
    local px, py, pz = X.position()
    env.ground = px and X.ground_height(px, py, pz) or nil

    -- profile, with hysteresis on the indoor / outdoor flip
    local want = wanted(env)
    local mode_changed = C.profile_mode ~= last_mode
    last_mode = C.profile_mode
    if want == env.profile then
        pending, pending_n = nil, 0
    elseif C.profile_mode ~= "auto" or mode_changed or want == "swim" or env.profile == "swim" then
        -- forced, just changed in the menu, or into / out of the water: at once
        env.profile = want
        pending, pending_n = nil, 0
        L.debug("profile: %s", want)
    elseif want == pending then
        pending_n = pending_n + 1
        if pending_n >= 2 then
            L.debug("profile: %s -> %s", env.profile, want)
            env.profile, pending, pending_n = want, nil, 0
        end
    else
        pending, pending_n = want, 1
    end
end

--- The value of `key` for the current profile, speed-scaled where it applies.
function P.get(key)
    local over = C.profiles[P.env.profile]
    local v = over and over[key]
    if v == nil then v = C[key] end
    if P.SCALED[key] and type(v) == "number" then v = v * P.env.factor end
    return v
end

--- Units count as obstacles now?
function P.avoid_units()
    if not C.avoid_units then return false end
    if P.env.combat and not C.avoid_units_in_combat then return false end
    return true
end

--- Ground check on now? (never while swimming: the probe answers the lake bed)
function P.ground_check()
    if not C.ground_check then return false end
    local over = C.profiles[P.env.profile]
    if over and over.ground_check == false then return false end
    return true
end

return P
