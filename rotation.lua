-- ============================================================================
-- Master Farmer - Grindbot
-- Class rotation dispatcher
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.204.0
-- Folder: Master_Farmer_Grindbot
-- Adding a class: create rotations/<class>.lua and register it here.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local targeting = require("targeting")
local combat = require("combat")
-- The rotation itself (2.64.0): built from the spells ticked in the Spells
-- tab. The class modules below still supply the class's shape - combat
-- range, melee or not, scan range, combat-movement profile, rest thresholds
-- and food - but no longer the spells.
local smart = require("smart")

-- ============================================================================
-- CLASS MODULES ARE LOADED ON DEMAND
-- ============================================================================
-- All eight used to be required here, at load, and seven of them were dead
-- weight for the rest of the session: a character has one class. Measured
-- resident, the eight came to 314 KB, of which the unused seven were 211 KB
-- for a mage and 290 KB for a rogue.
--
-- The map below is names only - requiring nothing - and the module behind a
-- class is pulled in the first time that class is actually asked for.
--
-- WARRIOR HAS NO ROTATION YET, and is absent here rather than present and
-- nil, so `supported` answers honestly without trying to load anything.
local CLASS_MODULES = {
    [enums.class_id.WARRIOR] = "rotations/warrior",
    [enums.class_id.PALADIN] = "rotations/paladin",
    [enums.class_id.HUNTER]  = "rotations/hunter",
    [enums.class_id.ROGUE]   = "rotations/rogue",
    [enums.class_id.PRIEST]  = "rotations/priest",
    [enums.class_id.SHAMAN]  = "rotations/shaman",
    [enums.class_id.MAGE]    = "rotations/mage",
    [enums.class_id.WARLOCK] = "rotations/warlock",
    [enums.class_id.DRUID]   = "rotations/druid",
}

local by_class = {}          -- class id -> module, once loaded
local load_failed = {}       -- class id -> true, so a bad module is not retried

--- The rotation for a class, loading it the first time it is wanted.
---
--- Returns nil for a class with no rotation, and for one whose module will
--- not load - the failure is remembered, because retrying a broken require
--- once per frame is its own problem.
local function module_for_class(class_id)
    if type(class_id) ~= "number" then
        return nil
    end
    local mod = by_class[class_id]
    if mod then
        return mod
    end
    if load_failed[class_id] then
        return nil
    end
    local name = CLASS_MODULES[class_id]
    if not name then
        return nil
    end

    local ok, loaded = pcall(require, name)
    if not ok or type(loaded) ~= "table" then
        load_failed[class_id] = true
        core.log_warning("[Master Farmer - Grindbot] Could not load " .. tostring(name))
        return nil
    end

    by_class[class_id] = loaded
    local label = enums.class_id_to_name and enums.class_id_to_name[class_id] or tostring(class_id)
    core.log("[Master Farmer - Grindbot] Loaded rotation for " .. tostring(label))
    return loaded
end

local rotation = {}

-- Flight-recorder probe (2.68.0). Free unless the Crash Recorder box is ticked:
-- then each one is a disk line, and the last line before a crash names the
-- native call the game died in.
local probe_el = nil
local function xprobe(tag)
    if probe_el == nil then
        local ok, m = pcall(require, "errorlog")
        probe_el = (ok and type(m) == "table" and type(m.probe) == "function") and m or false
    end
    if probe_el then
        pcall(probe_el.probe, tag)
    end
end

local last_action = "Idle"

-- ----------------------------------------------------------------------------
-- Movement is required lazily so the rotation dispatcher stays loadable even if
-- the movement module fails; `profile_mod` tracks which class's combat-movement
-- rules are currently installed so we only re-register on an actual change.
-- ----------------------------------------------------------------------------
local movement_mod = nil
local profile_mod = false          -- false = never synced, nil = cleared

local function get_movement()
    if movement_mod then return movement_mod end
    local ok, mod = pcall(require, "movement")
    if ok and type(mod) == "table" then movement_mod = mod end
    return movement_mod
end

-- healing and gui are lazily required for the same reason movement is: healing
-- requires rotation, and gui sits above this file in the load order. The
-- requires stay lazy; only the LOOKUP is remembered.
--
-- Both of these sit on per-frame paths - buffs_ooc and tick run every frame -
-- and each was paying a pcall and a package.loaded lookup on every one of
-- them. Resolved once, on the first call that succeeds.
--
-- Cached on success only. A call that lands before the module is loadable
-- must leave the slot empty and retry next frame, not remember the failure.
local healing_mod = nil
local gui_mod = nil

local function get_healing()
    if healing_mod then return healing_mod end
    local ok, mod = pcall(require, "healing")
    if ok and type(mod) == "table" then healing_mod = mod end
    return healing_mod
end

local function get_gui()
    if gui_mod then return gui_mod end
    local ok, mod = pcall(require, "gui")
    if ok and type(mod) == "table" then gui_mod = mod end
    return gui_mod
end

--- Install the active class's combat-movement profile (§17). The movement
--- controller owns positioning; the class only supplies the rules.
local function sync_profile(mod)
    if mod == profile_mod then return end
    profile_mod = mod
    local movement = get_movement()
    if not movement then return end
    if mod and type(mod.combat_profile) == "function" then
        local ok, p = pcall(mod.combat_profile)
        if ok and type(p) == "table" then
            movement.set_combat_profile(p)
            return
        end
    end
    movement.clear_combat_profile()
end

-- ----------------------------------------------------------------------------
-- RESTING AND SCANNING - both are the class's to decide
-- ----------------------------------------------------------------------------
--- Sit down and eat or drink, using the active class's thresholds.
---
--- A class that defines rest() owns the decision. Anything that does not falls
--- back to the shared default, so an unsupported class still eats.
function rotation.rest(player)
    if not player then
        return false
    end
    local mod = rotation.active(player)
    if mod and type(mod.rest) == "function" then
        local ok, acted = pcall(mod.rest, player)
        if ok then
            return acted == true
        end
    end
    local ok, resting = pcall(require, "resting")
    if ok and resting and type(resting.tick) == "function" then
        return resting.tick(player, nil) == true
    end
    return false
end

--- Is the bot sitting down right now?
function rotation.is_resting()
    local ok, resting = pcall(require, "resting")
    if ok and resting and type(resting.is_resting) == "function" then
        return resting.is_resting() == true
    end
    return false
end

--- How far out this class looks for something to fight. Melee scans tighter
--- than a caster: see the note on each rotation's scan_range.
function rotation.scan_range(player)
    -- One enemy search radius for every class (2.94.0): targeting.ENEMY_SCAN.
    -- Class differences live in the engage distance (combat_range), not here.
    return targeting.ENEMY_SCAN or 100
end

--- Does this class have a rotation? Answered from the name map, so asking
--- does not load anything.
function rotation.supported(class_id)
    return CLASS_MODULES[class_id] ~= nil
end

function rotation.module_for(class_id)
    return module_for_class(class_id)
end

function rotation.active(player)
    if not player then
        return nil
    end
    -- pcall carries its own arguments, so this needs no closure. rotation.active
    -- runs every frame, and the closure it used to build captured `player`, so
    -- it was a real allocation each time rather than a hoistable constant.
    local ok, class_id = pcall(player.get_class, player)
    if not ok then
        return nil
    end
    local mod = module_for_class(class_id)
    sync_profile(mod)
    return mod
end

function rotation.buffs_ooc(player)
    -- Buff casts cancel eating and drinking exactly like combat casts do.
    local healing = get_healing()
    if healing and type(healing.is_resting) == "function" then
        if healing.is_resting() == true then
            return false
        end
    end

    -- Racial escapes (a root or a fear) first, then every buff ticked in the
    -- Spells tab - in AND out of combat (2.64.0).
    rotation.active(player)       -- keeps the class's movement profile synced
    local ok_r, racials = pcall(require, "racials")
    if ok_r and racials and type(racials.ooc) == "function" and racials.ooc(player) then
        return true
    end
    return smart.upkeep(player) == true
end

--- Melee or not: the ticked spells first (a druid's Cat / Bear form, a
--- shaman's Stormstrike), then the class module, then the class module's own
--- range (5 or less = melee).
local function fights_in_melee(player)
    local sm = smart.is_melee(player)
    if type(sm) == "boolean" then
        return sm
    end
    local mod = rotation.active(player)
    if mod and type(mod.is_melee) == "function" then
        local ok, v = pcall(mod.is_melee, player)
        if ok and type(v) == "boolean" then
            return v
        end
    end
    if mod and type(mod.combat_range) == "function" then
        local ok, yards = pcall(mod.combat_range, player)
        if ok and type(yards) == "number" then
            return yards <= 5
        end
    end
    return false
end

local function slider(key, fallback)
    local gui = get_gui()
    if gui and type(gui.slider) == "function" then
        local v = gui.slider(key, fallback)
        if type(v) == "number" then return v end
    end
    return fallback
end

--- ENGAGE DISTANCE (2.90.0): how close the bot closes before the rotation
--- starts. Melee: the "Melee attack distance" slider (1-5 yd). Ranged: the
--- "Ranged attack distance" slider, never farther than the longest ticked
--- damage spell reaches (1 yd inside it). Combat movement closes to this, and
--- smart.combat holds offensive spells beyond it until the fight has begun.
function rotation.combat_range(player)
    local mod = rotation.active(player)
    -- A class that switches between ranged and melee by itself (the Hunter,
    -- 2.120.0) sets the engage distance from its own sliders and the live
    -- target.
    if mod and type(mod.engage_range) == "function" then
        local target = nil
        local ok_s, st = pcall(require, "state")
        if ok_s and type(st) == "table" and type(st.target) == "table" then
            local u = st.target.unit
            if u and pcall(function() return u:is_valid() end) then
                local okv, valid = pcall(u.is_valid, u)
                if okv and valid == true then target = u end
            end
        end
        local ok, yards = pcall(mod.engage_range, player, target)
        if ok and type(yards) == "number" and yards > 0 then
            -- A ranged engage distance is capped by the Ranged attack
            -- distance slider (2.181.0): the shaman's own answer was Lightning
            -- Bolt reach, so the slider did nothing for it.
            if yards > 5 then
                local want = slider("ranged_yards", yards)
                if type(want) == "number" and want >= 8 and want < yards then
                    yards = want
                end
            end
            return yards
        end
    end
    if fights_in_melee(player) then
        local m = slider("melee_yards", 5)
        if m < 1 then m = 1 elseif m > 5 then m = 5 end
        return m
    end
    -- THE GUI DISTANCE FIRST (2.139.0). The class reach (Frostbolt, Mind
    -- Flay, Lightning Bolt, Wrath) used to win and the Ranged attack distance
    -- slider was read only for a class without one, so the setting did
    -- nothing. Now the slider is the distance; the class reach is only its
    -- default. Never farther than 1 yard inside the longest ticked damage
    -- spell, never inside melee.
    local default = 30
    if mod and type(mod.combat_range) == "function" then
        local ok, yards = pcall(mod.combat_range, player)
        if ok and type(yards) == "number" and yards > 5 then default = yards end
    end
    local want = slider("ranged_yards", default)
    local reach = smart.max_range(player)
    if type(reach) == "number" and reach > 6 and want > reach - 1 then
        want = reach - 1
    end
    if want < 8 then want = 8 end
    return want
end

--- Does the active rotation fight in melee?
---
--- A rotation may say so itself (is_melee); otherwise a combat range of 5
--- yards or less means melee - every melee rotation reports exactly 5.
--- Combat movement closes melee to 2 yards of the target (2.26.0).
function rotation.is_melee(player)
    return fights_in_melee(player)
end

function rotation.tick(player, target, ctx)
    -- Nothing in the combat routine may fire during a rest: every cast and
    -- the auto-attack start below cancels eating or drinking. main.lua already
    -- returns before this, but a grind or quest engine calling rotation.tick
    -- directly would bypass that. Lazy require - healing requires rotation.
    local healing = get_healing()
    if healing and type(healing.is_resting) == "function" then
        if healing.is_resting() == true then
            return false
        end
    end

    -- The class module's own tick was retired with the Spells-tab rotation
    -- (2.64.0) and removed in 2.142.0; any loaded class module will do.
    local mod = rotation.active(player)
    if not mod or type(mod.combat_range) ~= "function" then
        return false
    end

    -- Resolve the target through the combat engine. The caller's own live
    -- target always wins; the latch only fills in when that target is gone,
    -- so a grind or quest route keeps deciding what to fight.
    ctx = ctx or {}
    local pack = ctx.enemies
    if type(pack) ~= "table" then
        pack = nil
    end
    -- A grind / quest / path engine (ctx.no_move) decides what to fight. If
    -- the target it handed over has died, stop here: combat.acquire would
    -- otherwise pick a new one and set_current it, and the engine and the
    -- rotation would be choosing targets against each other.
    if ctx.no_move and target ~= nil then
        local ok_v, valid = pcall(target.is_valid, target)
        if not (ok_v and valid == true) then
            return false
        end
        local ok_d, dead = pcall(target.is_dead_or_ghost, target)
        if ok_d and dead == true then
            return false
        end
    end
    xprobe("r:acquire")
    local resolved, scanned = combat.acquire(player, rotation.combat_range(player), target, pack)
    if resolved then
        target = resolved
        ctx.enemies = scanned
    end

    xprobe("r:dismount")
    if combat.dismount(player, target) then
        return true
    end

    -- Interrupts across the whole pack now happen inside smart.combat, with
    -- the interrupt spells ticked in the Spells tab (2.64.0).

    if player and target and targeting and type(targeting.start_auto_attack) == "function" then
        xprobe("r:auto_attack")
        targeting.start_auto_attack(player, target)
    end
    -- Facing is idempotent and throttled inside movement, so asserting it here
    -- is safe even when combat movement is already facing the same target.
    -- This is a facing command, never a movement command.
    --
    -- It used to run in Rotation Only too, on the reasoning that a mode with
    -- no combat movement still wants to be pointed the right way. That is the
    -- bot turning the camera under a player who is steering by hand, so it is
    -- off there now: in Rotation Only the character faces wherever the player
    -- points it and the rotation casts at whatever is already targeted.
    --
    -- ctx.no_move is NOT the test. Every caller passes it - grind, quest and
    -- the path runner all mean "you do not own movement, I do" by it - so
    -- gating on it would stop the bot facing its target while grinding.
    -- Lazy require, like healing above: gui is a large module and this file
    -- sits under it in the load order.
    local rotation_only = false
    local gui = get_gui()
    if gui and type(gui.is_on) == "function" then
        rotation_only = gui.is_on("rotation_only") == true
    end
    if target and not rotation_only then
        local movement = get_movement()
        if movement then
            xprobe("r:face")
            movement.face(target)
        end
    end
    -- The engage distance, for smart.combat's "not before" gate - not in
    -- Rotation Only, where the player decides when the fight starts.
    if not rotation_only then
        ctx.engage = rotation.combat_range(player)
    end
    xprobe("r:smart")
    local acted = smart.combat(player, target, ctx) == true
    xprobe("r:smart done")
    return acted
end

function rotation.preferred_food_ids(player)
    local mod = rotation.active(player)
    if mod and type(mod.preferred_food_ids) == "function" then
        return mod.preferred_food_ids()
    end
    return nil
end

function rotation.preferred_drink_ids(player)
    local mod = rotation.active(player)
    if mod and type(mod.preferred_drink_ids) == "function" then
        return mod.preferred_drink_ids()
    end
    return nil
end

function rotation.set_last_action(text)
    if type(text) == "string" and text ~= "" then
        last_action = text
    end
end

function rotation.last_action()
    return last_action
end

function rotation.class_labels()
    return {
        { id = enums.class_id.WARRIOR, label = "Warrior" },
        { id = enums.class_id.PALADIN, label = "Paladin" },
        { id = enums.class_id.HUNTER, label = "Hunter" },
        { id = enums.class_id.ROGUE, label = "Rogue" },
        { id = enums.class_id.PRIEST, label = "Priest" },
        { id = enums.class_id.SHAMAN, label = "Shaman" },
        { id = enums.class_id.MAGE, label = "Mage" },
        { id = enums.class_id.WARLOCK, label = "Warlock" },
        { id = enums.class_id.DRUID, label = "Druid" },
    }
end

return rotation
