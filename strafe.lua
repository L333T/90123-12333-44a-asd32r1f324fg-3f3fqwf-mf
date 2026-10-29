-- ============================================================================
-- restedXP_questing
-- strafe.lua - Rogue / Warrior "Strafe Combat": now a shim over the engine
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.46.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.46.0 (the Astar movement engine port, group A): the taps themselves moved
-- to engine/combat/verbs.lua as the `orbit` verb - the same key order and the
-- same timings this file used:
--     right: strafe_right_start, move_forward_start ... move_forward_stop, strafe_right_stop
--     left:  move_forward_start, strafe_left_start  ... move_forward_stop, strafe_left_stop
--   each tap 0.20-0.50 s, 0.06-0.12 s between taps, the forward key holding the
--   character in the swing band.
--
-- WHY A SHIM AND NOT A DELETED FILE. main.lua calls strafe.update() once a
-- frame after the decision cascade, and strafe.stop() when its instance goes
-- stale or the bot stops. Those call sites are the contract; this file keeps
-- them working and the engine does the work.
--
-- WHO TAPS NOW. engine/combat/registry.lua picks one verb a frame. `orbit` is
-- registered above `close` for the Rogue ("Strafe Combat") and the Warrior
-- ("Strafe in Combat") and its gate is the same one this file used: in combat,
-- the box ticked, and in position on a live target. The registry is ticked from
-- movement/combat.lua's combat_engage, which runs inside the cascade - so a
-- band that was just lost releases the keys on that same frame, exactly as the
-- old ordering comment in main.lua describes.
--
-- WHAT IS LEFT TO DO HERE. Only the safety net: when the cascade did not reach
-- combat_engage on this frame (no fight, the bot stopped, a stale instance),
-- nothing would have ticked the registry, so a held tap is released here.
-- ============================================================================

local strafe = {}

local combat_mod = nil
local registry_mod = nil
local verbs_mod = nil

local function get(name, cache_set)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then
        cache_set(mod)
        return mod
    end
    return nil
end

local function combat()
    if combat_mod == nil then
        combat_mod = get("movement/combat", function(m) combat_mod = m end) or false
    end
    return combat_mod or nil
end

local function registry()
    if registry_mod == nil then
        registry_mod = get("engine/combat/registry", function(m) registry_mod = m end) or false
    end
    return registry_mod or nil
end

local function verbs()
    if verbs_mod == nil then
        verbs_mod = get("engine/combat/verbs", function(m) verbs_mod = m end) or false
    end
    return verbs_mod or nil
end

--- Once per frame from main.lua, after the cascade. The taps are the engine's;
--- this only lets go of a key the cascade can no longer be reaching.
function strafe.update()
    local C = combat()
    if C and type(C.in_combat_movement) == "function" then
        local ok, owned = pcall(C.in_combat_movement)
        if ok and owned == true then
            return                      -- combat_engage ticked the registry this frame
        end
    end
    strafe.stop()
end

--- Let go of any held key. Safe at any time; does nothing when none is down.
function strafe.stop()
    local Rg = registry()
    if Rg and type(Rg.release) == "function" then
        pcall(Rg.release)
        return
    end
    local V = verbs()
    if V and type(V.release_all) == "function" then
        pcall(V.release_all)
    end
end

--- True while a strafe tap is held (the Rogue / Warrior orbit verb is active).
function strafe.active()
    local Rg = registry()
    if not Rg or type(Rg.active_id) ~= "function" then return false end
    local ok, id = pcall(Rg.active_id)
    if not ok or type(id) ~= "string" then return false end
    return id:find("orbit", 1, true) ~= nil
end

return strafe
