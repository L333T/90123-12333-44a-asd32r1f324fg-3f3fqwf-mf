-- ============================================================================
-- Master Farmer - Grindbot
-- Hunter grind filler + OOC buffs (TBC)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.255.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Pet handling lives in pets.lua, shared with the Warlock.
--
-- THE DEAD ZONE
--   A Hunter cannot shoot inside roughly 8 yards and its melee is weak, so the
--   combat profile keeps the target OUT, not in. This is the only class here
--   whose melee_danger means "too close to shoot" rather than "about to die",
--   which is why it is the only one that retreats unconditionally when closed
--   on - see combat_profile.
--
-- SPELL IDS
--   Highest rank first. A wrong id fails CLOSED but silently; mfg_hunter_debug
--   prints what the scanner actually resolved. Run it once before trusting the
--   rotation.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local gui = require("gui")
local resting = require("resting")
local racials = require("racials")
local pets = require("pets")
local state = require("state")
local spellbook = require("spellbook")
local auras = require("auras")

local hunter = {}

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
function hunter.class_id() return enums.class_id.HUNTER end
function hunter.label() return "Hunter" end

-- ----------------------------------------------------------------------------
-- RANGES AND THE MELEE / RANGED SWITCH (2.120.0)
-- ----------------------------------------------------------------------------
-- The gun range and the dead zone come from Auto Shot itself (the spellbook's
-- min / max range), not from constants: the dead zone was a hard-coded 8 yd
-- and the combat range a hard-coded 34, and the Ranged attack distance slider
-- defaulted to 25 - well short of a gun's reach.
--
-- A Hunter is ranged AND melee:
--   * outside the dead zone it shoots, standing at the Shooting distance
--     (GUI, default 35 = max gun range, capped 1 yd inside the real range);
--   * inside the dead zone it steps back out and shoots again ONLY when that
--     can work - the pet holds the mob, or the mob is slowed or rooted (Wing
--     Clip, Concussive Shot, Frost Trap, Entrapment);
--   * otherwise it stays and fights in melee at the Melee distance (GUI,
--     default 5): Wing Clip, Raptor Strike, Mongoose Bite and melee swings.
--     Wing Clip landing makes the mob kitable, so the next tick backs off.
-- The old profile backed off from anything inside 8 yd, always: a mob on the
-- hunter just followed, and the bot stepped back, got hit, stepped back.
--
-- MELEE BAND AND 40-YARD RANGE (2.222.0)
--   Replaces the kite-out rule above. At or inside MELEE_BAND (11 yd) the
--   Hunter always fights in melee: it closes to MELEE_CLOSE (3 yd), swings
--   and uses the ticked melee spells; no shot is cast there (the shots carry
--   min = 11 in data/class_spells). Beyond it, Auto Shot and the ticked
--   shots, from the Shooting distance - at most RANGED_MAX (40 yd), and never
--   past the weapon's real reach, where no shot can land.
local AUTO_SHOT_ID = 75
local DEAD_ZONE_FALLBACK = 8
local GUN_RANGE_FALLBACK = 35
local MELEE_BAND = 11
local MELEE_CLOSE = 3
local RANGED_MAX = 40
local SNARE_IDS = {
    2974, 14267, 14268,          -- Wing Clip
    19229,                       -- Improved Wing Clip (root)
    5116,                        -- Concussive Shot
    13810,                       -- Frost Trap Aura
    19185,                       -- Entrapment (root)
    19503,                       -- Scatter Shot
    3355, 14308, 14309,          -- Freezing Trap
}
local range_cache = { t = -1, min = nil, max = nil }

local function spell_ranges()
    local now = izi.now()
    if (now - range_cache.t) < 10 and range_cache.min then
        return range_cache.min, range_cache.max
    end
    local mn = safe(function() return core.spell_book.get_spell_min_range(AUTO_SHOT_ID) end)
    local mx = safe(function() return core.spell_book.get_spell_max_range(AUTO_SHOT_ID) end)
    if type(mn) ~= "number" or mn <= 0 or mn > 15 then mn = DEAD_ZONE_FALLBACK end
    if type(mx) ~= "number" or mx < 20 or mx > 50 then mx = GUN_RANGE_FALLBACK end
    range_cache.t, range_cache.min, range_cache.max = now, mn, mx
    return mn, mx
end

--- At or inside this many yards the Hunter fights in melee (2.222.0): the
--- 11-yard band, or the game's own dead zone if that is ever wider.
function hunter.dead_zone()
    local mn = spell_ranges()
    if mn > MELEE_BAND then return mn end
    return MELEE_BAND
end

hunter.MELEE_BAND = MELEE_BAND
hunter.MELEE_CLOSE = MELEE_CLOSE
hunter.RANGED_MAX = RANGED_MAX

--- The gun's (bow's, crossbow's) real reach.
function hunter.gun_range()
    local _, mx = spell_ranges()
    return mx
end

local function slider(key, fallback)
    if type(gui.slider) == "function" then
        local v = gui.slider(key, fallback)
        if type(v) == "number" then return v end
    end
    return fallback
end

--- Can the hunter open the gap on `target`? The pet (or anyone else) holds
--- it, or it is slowed / rooted - then stepping back out of the dead zone
--- works. A mob that is on the hunter and moving freely just follows.
function hunter.can_kite(player, target)
    if not player or not target then return false end
    local tt = safe(function() return target:get_target() end)
    local tg = tt and safe(function() return tt:get_guid() end) or nil
    local me = safe(function() return player:get_guid() end)
    if tg == nil or me == nil or tg ~= me then
        return true
    end
    return auras.debuff_up(target, SNARE_IDS) == true
end

--- Fight this target in melee right now? At or inside the melee band,
--- always (2.222.0) - no stepping back out to shoot.
function hunter.melee_mode(player, target)
    if not player or not target then return false end
    local d = safe(function() return player:distance_to(target) end)
    return type(d) == "number" and d <= hunter.dead_zone()
end

--- The engage distance rotation.combat_range uses for a Hunter: the Melee
--- distance while fighting in melee, the Shooting distance otherwise.
function hunter.engage_range(player, target)
    if hunter.melee_mode(player, target) then
        local m = slider("melee_yards", MELEE_CLOSE)
        if m < 1 then m = 1 elseif m > MELEE_CLOSE then m = MELEE_CLOSE end
        return m, true
    end
    local want = slider("ranged_yards", 25)
    local reach = hunter.gun_range() - 1
    if reach > RANGED_MAX then reach = RANGED_MAX end
    if want > reach then want = reach end
    local floor = hunter.dead_zone() + 2
    if want < floor then want = floor end
    return want, false
end

function hunter.combat_range(player)
    local r = hunter.gun_range() - 1
    if r > RANGED_MAX then r = RANGED_MAX end
    return r
end
function hunter.is_melee(player) return false end

-- The dead zone: a Hunter cannot shoot inside ~8 yards. Unlike every other
-- caster here, being closed on is a DPS problem rather than a survival one, and
-- the pet is holding threat anyway - so this retreats whenever something is in
-- melee, with no profile condition to satisfy.
--- How far out to look for something to fight.
---
--- A hunter pulls at range and has a pet to hold what it pulls,
--- so it wants the same warning a caster does.
function hunter.scan_range(player)
    return 100
end

function hunter.combat_profile()
    local dz = hunter.dead_zone()
    return {
        name         = "hunter",
        melee_danger = dz,
        melee_safe   = dz + 6,
        -- No backing out (2.222.0): inside the melee band the Hunter closes
        -- to 3 yd and fights in melee.
        should_retreat = function(ctx)
            return false
        end,
    }
end

-- ----------------------------------------------------------------------------
-- COMBAT
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- RESTING
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink. The thresholds are this class's to choose; the
--- machinery lives in resting.lua so a fix lands once rather than nine times.
function hunter.rest(player)
    return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
end

return hunter
