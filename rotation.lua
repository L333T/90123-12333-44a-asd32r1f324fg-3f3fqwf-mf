-- ============================================================================
-- Master Farmer - Grindbot
-- Class rotation dispatcher
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.12.1
-- Folder: Master_Farmer_Grindbot
-- Adding a class: create rotations/<class>.lua and register it here.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local targeting = require("targeting")
local combat = require("combat")

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
    local mod = player and rotation.active(player) or nil
    if mod and type(mod.scan_range) == "function" then
        local ok, yards = pcall(mod.scan_range, player)
        if ok and type(yards) == "number" and yards >= 5 then
            return yards
        end
    end
    return 30
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
    local ok, class_id = pcall(function()
        return player:get_class()
    end)
    if not ok then
        return nil
    end
    local mod = module_for_class(class_id)
    sync_profile(mod)
    return mod
end

--- Register the class checkboxes.
---
--- Only the player's own class is registered, which is the whole point: the
--- other seven modules are never loaded. The class is read here, at load,
--- because Sylvanas takes its menu elements at load - registering them later
--- is the mismatch picks.lua exists to work around, and is not something to
--- rely on.
---
--- If the player cannot be read yet, every class is registered instead. That
--- is exactly the old behaviour, so the fallback costs memory rather than
--- function, and the menu is never short of a checkbox.
function rotation.register_gui(menu)
    local class_id = nil
    pcall(function()
        local me = izi.me()
        if me then
            class_id = me:get_class()
        end
    end)

    if type(class_id) == "number" and CLASS_MODULES[class_id] then
        local mod = module_for_class(class_id)
        if mod and type(mod.register_gui) == "function" then
            pcall(mod.register_gui, menu)
            return
        end
    end

    core.log_warning(
        "[Master Farmer - Grindbot] Class unknown at load; registering every rotation")
    for id, _ in pairs(CLASS_MODULES) do
        local mod = module_for_class(id)
        if mod and type(mod.register_gui) == "function" then
            pcall(mod.register_gui, menu)
        end
    end
end

function rotation.buffs_ooc(player)
    -- Buff casts cancel eating and drinking exactly like combat casts do.
    local ok_h, healing = pcall(require, "healing")
    if ok_h and healing and type(healing.is_resting) == "function" then
        if healing.is_resting() == true then
            return false
        end
    end

    local mod = rotation.active(player)
    if not mod or type(mod.buffs_ooc) ~= "function" then
        return false
    end
    return mod.buffs_ooc(player) == true
end

function rotation.combat_range(player)
    local mod = rotation.active(player)
    if mod and type(mod.combat_range) == "function" then
        local yards = mod.combat_range(player)
        if type(yards) == "number" and yards > 0 then
            return yards
        end
    end
    return 30
end

function rotation.tick(player, target, ctx)
    -- Nothing in the combat routine may fire during a rest: every cast and
    -- the auto-attack start below cancels eating or drinking. main.lua already
    -- returns before this, but a grind or quest engine calling rotation.tick
    -- directly would bypass that. Lazy require - healing requires rotation.
    local ok_h, healing = pcall(require, "healing")
    if ok_h and healing and type(healing.is_resting) == "function" then
        if healing.is_resting() == true then
            return false
        end
    end

    local mod = rotation.active(player)
    if not mod or type(mod.tick) ~= "function" then
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
    local resolved, scanned = combat.acquire(player, rotation.combat_range(player), target, pack)
    if resolved then
        target = resolved
        ctx.enemies = scanned
    end

    if combat.dismount(player, target) then
        return true
    end

    -- Interrupt / taunt / aggro dump across the whole pack, before the damage
    -- rotation. Each rotation only ever interrupted its CURRENT target, so a
    -- mob casting behind the one being hit finished its cast unchallenged.
    if combat.assist(player, target, ctx.enemies, mod) then
        return true
    end

    if player and target and targeting and type(targeting.start_auto_attack) == "function" then
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
    local ok_g, gui = pcall(require, "gui")
    if ok_g and gui and type(gui.is_on) == "function" then
        rotation_only = gui.is_on("rotation_only") == true
    end
    if target and not rotation_only then
        local movement = get_movement()
        if movement then
            movement.face(target)
        end
    end
    return mod.tick(player, target, ctx) == true
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
