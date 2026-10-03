-- ============================================================================
-- Master Farmer - Grindbot
-- movement/const.lua - enums, tunables and engine flags
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.209.0
-- ============================================================================
-- Immutable. Every value here was a top-level `local` in the old movement.lua.
-- Modules pull the handful they need into their own locals at load time, so the
-- hot path still reads an upvalue and not a table field.
-- ============================================================================

---@type enums
local enums = require("common/enums")

local K = {}

-- ----------------------------------------------------------------------------
-- ENUMS
-- ----------------------------------------------------------------------------
K.STATE = {
    IDLE       = "IDLE",
    NAVIGATION = "NAVIGATION",
    COMBAT     = "COMBAT",
    RESTRICTED = "RESTRICTED",
}

K.OWNER = {
    NONE   = "NONE",
    NAV    = "NAV",
    COMBAT = "COMBAT",
}

-- why movement is currently impossible / unsafe (highest priority first)
K.RESTRICT = {
    INVALID = "invalid",
    DEAD    = "dead",
    STUN    = "stunned",
    FEAR    = "feared",
    INCAP   = "incapacitated",
    DISORI  = "disoriented",
    ROOT    = "rooted",
    REST    = "resting",
    CAST    = "casting",
}

-- ----------------------------------------------------------------------------
-- TUNABLES
-- ----------------------------------------------------------------------------
K.TAG              = "[Master Farmer - Grindbot]"

-- navigation
K.MIN_NAV          = 2.0    -- never issue a move shorter than this
K.MIN_NAV_TRAVEL   = 4.0    -- travel dests closer than this are arrival, not a walk
K.ARRIVE           = 2.0
K.SAME_DEST        = 6.0    -- destinations closer than this are "the same"
K.MOVE_GAP         = 0.85   -- seconds between navigation moves
K.COMBAT_GAP       = 0.5    -- seconds between combat moves
K.INFLIGHT_TIMEOUT = 8.0    -- an issued move counts as moving for this long
K.FAIL_COOLDOWN    = 6.0
K.QUIET_STOP       = 1.25
K.QUIET_OFFMESH    = 5.0
K.PATROL_HOP       = 40.0   -- nav hop length when the direct line is clear
K.STEER_HOP        = 5.0    -- combat / avoidance hop length
K.STEER_BACKOFF    = 0.5    -- seconds before retrying a steer that found nothing
K.PATH_LEASH       = 10.0

-- blacklist zones
K.ZONE_RADIUS      = 12.0
K.ZONE_MERGE       = 10.0
K.ZONE_TTL         = 900.0
K.ZONE_PRUNE_EVERY = 5.0
K.MAX_ZONES        = 24

-- stuck watch
K.STUCK_ZONE_RADIUS = 14.0
K.STUCK_GRACE      = 4.0
K.STUCK_MOVE       = 1.5    -- yards of progress that resets the stuck timer

-- geometry
K.EYE_Z            = 1.6
K.TRACE_BUDGET     = 40     -- trace lines per pulse (2.82.0: body corridor = up to 4)
K.SIDESTEP_YARDS   = { 4, 8 }
K.OFFSET_DEGREES   = { 35, -35, 70, -70 }
K.ORBIT_DEGREES    = { 45, -45, 90, -90 }
K.COMBAT_OFFSET    = { 45, -45, 90, -90 }
-- after repeated blocked passes the search widens: walk along, then back around
K.ESCALATE = {
    { angles = K.OFFSET_DEGREES,         hop = nil },
    { angles = { 70, -70, 110, -110 },   hop = 8.0 },
    { angles = { 110, -110, 150, -150 }, hop = 12.0 },
}

-- state machine
K.SETTLE           = 0.35   -- a de-escalation must hold this long
K.COMBAT_EXIT_HOLD = 1.5    -- every combat-end condition must hold this long
K.COMBAT_REQ_TTL   = 0.35   -- a combat request stays live this long between bot ticks
K.CHASE_GIVE_UP    = 10.0   -- blacklist a mob we could not reach for this long
K.SN_MIN_GAP       = 1.0    -- seconds between any two Sentinel move_to requests
-- 2.109.0: out of combat every move goes through Sentinel's pathing - no
-- walker / movement-handler legs. The walker is used out of combat only when
-- Sentinel itself is unavailable (not loaded, server down).
K.SENTINEL_TRAVEL  = true
K.SN_FAIL_HOLD     = 3.0    -- seconds a destination Sentinel just failed is not re-requested
K.MAX_LEG          = 300    -- yards: no navigation leg or path request is longer

-- Melee contact (2.26.0). A combat range at or below MELEE_YARDS marks the
-- fighter as melee; melee counts as in position only within MELEE_REACH of
-- the target.
--
-- It aims at the target's own position (MELEE_STANDOFF 0), not a point short
-- of it. 2.26.0 aimed 1 yard short, and the walker treats a destination
-- within its 1-yard final threshold as already reached: from 2-2.5 yards out
-- the hop "arrived" without moving, the range never dropped to 2, and the bot
-- re-issued the same hop every half second for the whole fight. Aiming at the
-- target makes every hop at least MELEE_REACH long, and the walker stops
-- within 1 yard of it - inside MELEE_REACH.
--
-- 2.45.0: aiming AT the target ran the character into and through it; it
-- overshot, turned back and circled, re-chasing each time the gap opened past
-- 2 yards. Melee now aims MELEE_STANDOFF (3 yd) short, is in position within
-- MELEE_REACH (4 yd), and only chases again past MELEE_HOLD (5 yd) - still
-- inside swing range - so small shuffles of the target do not restart it.
K.MELEE_YARDS      = 5.0
K.MELEE_REACH      = 4.0
K.MELEE_HOLD       = 5.0
K.MELEE_STANDOFF   = 3.0
K.MELEE_MIN_HOP    = 1.0    -- the walker's final threshold: shorter hops are not issued
K.CHASE_REISSUE    = 2.0    -- yards the target must shift before a direct chase is re-aimed
K.PULL_RETRY       = 3.0    -- seconds before re-trying a combat pull-in leg
K.PULL_MAX_TRIES   = 3      -- pull-in legs per mob before it counts as unreachable

-- combat hysteresis. Bands are relative to the rotation's own max range, so
-- nothing here invents a mechanic the rotation has not already defined.
K.CHASE_BAND       = 3.0    -- stop chasing this far inside max range
K.RETREAT_BAND     = 4.0    -- retreat until this far past melee_danger
K.DEFAULT_MELEE_DANGER = 8.0
K.FACE_GAP         = 0.35   -- seconds between facing commands
K.FACE_LOCK        = 0.8    -- look_at lock duration
K.PREDICT_AHEAD    = 0.5    -- seconds of lookahead for closing enemies
K.PREDICT_MARGIN   = 1.5    -- predicted distance must beat the band by this

-- diagnostics
K.LOG_REPEAT       = 2.0    -- same debug line is not reprinted inside this

K.OFFMESH_WORDS = { "navmesh", "unreachable", "blocked", "blacklisted", "422", "max_stuck" }
K.SN_NEED = { "move_to", "follow_path", "stop", "is_moving", "get_state", "validate_destination" }

-- ----------------------------------------------------------------------------
-- ENGINE FLAGS
-- ----------------------------------------------------------------------------
K.FLAG_COLLISION, K.FLAG_LOS, K.FLAG_OBSTACLE = nil, nil, nil
do
    local cf = type(enums) == "table" and enums.collision_flags
    if type(cf) == "table" then
        if type(cf.Collision) == "number" then K.FLAG_COLLISION = cf.Collision end
        if type(cf.LineOfSight) == "number" then K.FLAG_LOS = cf.LineOfSight end
        -- Objects only, no terrain (2.82.0): doodads (rocks, fences, crates,
        -- trees), buildings and entities. Used for the knee-height and
        -- shoulder rays, where terrain would read every slope as a wall.
        local d, w, e = cf.DoodadCollision, cf.WmoCollision, cf.EntityCollision
        if type(d) == "number" and type(w) == "number" and type(e) == "number" then
            K.FLAG_OBSTACLE = d + w + e
        end
    end
end

-- Avoidance corridor geometry (2.82.0), yards.
K.BODY_HALF   = 0.5    -- half the body width: the shoulder rays' offset
K.KNEE_Z      = 0.5    -- low obstacles: rocks, fences, crates, stumps
K.CHEST_Z     = 1.3    -- walls, trees, cliffs (with terrain)
K.LOOKAHEAD   = 4.0    -- how far ahead a walking move is re-checked
K.LOOK_GAP    = 0.25   -- seconds between look-ahead checks
-- 2.85.0: moving without stopping
K.BODY_HALF_TIGHT = 0.25  -- narrow-passage retry half width
K.CHAIN_DIST  = 1.8    -- yards before a hop's end at which the next hop is issued

return K
