-- ============================================================================
-- restedXP_questing
-- Swing timer - when the player's (and the pet's) melee swings really land
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.33.0
-- Folder: restedXP_questing
-- ============================================================================
-- WHY (4.33.0)
--   auto_attack_helper's last / next attack times move when the Attack
--   command goes out, not on every swing (seen in the 2.293.0 warrior
--   session). After the first swing its "next attack" is always in the
--   past, so:
--     * adapt.swing_ok said yes to every cast - no melee weaving at all;
--     * adapt.swing_now never saw a swing - melee hits were measured as
--       spell damage;
--     * the swing watch only saw hits that took health - a dodged or
--       parried swing read as "no swing", and the character turned.
--
-- HOW
--   The core pumps COMBAT_LOG_EVENT_UNFILTERED to the game event callback
--   (events.lua) with the CombatLogGetCurrentEventInfo() payload flattened:
--     1 timestamp, 2 sub_event, 3 hide_caster, 4 source_guid, 5 source_name,
--     6 source_flags, 7 source_raid_flags, 8 dest_guid, ...
--   SWING_DAMAGE  12 amount ... 21 is_off_hand
--   SWING_MISSED  12 miss_type, 13 is_off_hand
--   A swing by the player or the player's pet is stamped with core.time()
--   (the clock auto_attack_helper uses), main hand and off hand apart.
--   Nothing else in the combat log is looked at.
--
--   The next main-hand swing is the last one plus get_attack_speed(). With no
--   swing seen (the event pump is off on an old core, the first swing of a
--   fight) the readers fall back to auto_attack_helper as before.
-- ============================================================================

local swingtimer = {}

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function now()
    return tonumber(safe(core.time)) or 0
end

-- [guid] = { mh = core.time, oh = core.time, dest = guid }
local swings = {}
local me = { t = -1e9, player = nil, pet = nil }
local seen = 0                 -- swings recorded this session (status / tests)

-- The player's and the pet's GUID, read at most once a second.
local function refresh_me()
    local t = now()
    if t - me.t < 1 then return end
    me.t = t
    local p = safe(function() return core.object_manager.get_local_player() end)
    if not p then me.player, me.pet = nil, nil return end
    me.player = safe(p.get_guid, p)
    local pet = safe(p.get_pet, p)
    me.pet = pet and safe(pet.get_guid, pet) or nil
end

--- COMBAT_LOG_EVENT_UNFILTERED handler (events.lua).
function swingtimer.on_cleu(args)
    if type(args) ~= "table" then return end
    local sub = args[2]
    if sub ~= "SWING_DAMAGE" and sub ~= "SWING_MISSED" then return end
    local src = args[4]
    if type(src) ~= "string" then return end
    refresh_me()
    if src ~= me.player and src ~= me.pet then return end
    local off
    if sub == "SWING_DAMAGE" then off = args[21] else off = args[13] end
    local rec = swings[src]
    if not rec then rec = {} swings[src] = rec end
    local t = now()
    if off == true or off == 1 then rec.oh = t else rec.mh = t end
    rec.dest = args[8]
    seen = seen + 1
end

local function guid_of(unit)
    if type(unit) == "string" then return unit end
    if unit == nil then return nil end
    return safe(unit.get_guid, unit)
end

--- core.time() of `unit`'s last swing (either hand), or nil when none was seen.
function swingtimer.last(unit)
    local rec = swings[guid_of(unit) or ""]
    if not rec then return nil end
    if rec.mh and rec.oh then return math.max(rec.mh, rec.oh) end
    return rec.mh or rec.oh
end

--- core.time() of `unit`'s last MAIN-HAND swing, or nil.
function swingtimer.last_mh(unit)
    local rec = swings[guid_of(unit) or ""]
    return rec and rec.mh or nil
end

local function speed_of(unit)
    local s = type(unit) ~= "string" and unit and tonumber(safe(unit.get_attack_speed, unit)) or nil
    if not s or s <= 0 or s > 10 then return nil end
    return s
end

--- Predicted core.time() of `unit`'s next main-hand swing, and the weapon
--- speed. nil when no swing of this fight was seen (older than two swings
--- and a second: the timer has lapsed - out of range, target dead).
function swingtimer.next_mh(unit)
    local last = swingtimer.last_mh(unit)
    local spd = speed_of(unit)
    if not last or not spd then return nil, spd end
    local nxt = last + spd
    if now() - last > 2 * spd + 1 then return nil, spd end
    return nxt, spd
end

--- True once the combat log has delivered a swing this session.
function swingtimer.live() return seen > 0 end
function swingtimer.count() return seen end

-- Tests.
function swingtimer._reset()
    swings, seen = {}, 0
    me.t, me.player, me.pet = -1e9, nil, nil
end

return swingtimer
