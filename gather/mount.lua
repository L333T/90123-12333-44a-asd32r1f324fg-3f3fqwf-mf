-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering: mount up for travel (PORT_PLAYBOOK "Mount and dismount")
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.254.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Called by gather/engine.lua while travelling when the next point is more
-- than TRAVEL_YARDS away. Gates (the playbook's, in order):
--   * disable for 120 s: level >= 30 with no usable mount (not warlock /
--     druid), a warlock at level <= 40, a druid without Travel Form
--   * druid with Travel Form: shift into it (aura missing, castable, >= 1 s
--     since the last shift) and never also mount
--   * otherwise mount when: not mounted, level >= 30, not a ghost, the Use
--     Mount box on, not suppressed, not in combat, not swimming, outdoors.
--     The first get_mount_info(i) with is_usable goes to core.input.mount(i).
--   * 5 failed tries -> no mounting for 15 s
--   * gather/engine suppresses mounting for 10 s near a node (30 yd)
-- Dismounting (node, eat / drink) is done by the callers with
-- core.input.dismount().
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local spellbook = require("spellbook")

local mount = {}

mount.TRAVEL_YARDS = 15

local CLASS_WARLOCK, CLASS_DRUID = 9, 11
local VERIFY = 3.0           -- a mount cast is 1.5 s (3 s on Classic level 30 mounts)

local blocked_until = 0
local suppress_until = 0
local tries = 0
local pending_at = nil
local last_shift = 0

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function now() return izi.now() or 0 end

local function usable_mount_index()
    local n = safe(function() return core.spell_book.get_mount_count() end)
    if type(n) ~= "number" or n <= 0 then return nil end
    for i = 0, n do
        local info = safe(function() return core.spell_book.get_mount_info(i) end)
        if type(info) == "table" and info.is_usable == true then return i end
    end
    return nil
end

local function has_aura_named(player, name)
    local fam = spellbook.family(name)
    if not fam or not fam.ranks then return false end
    return safe(function() return player:has_buff(fam.ranks) end) == true
end

---Hold mounting off for `seconds` (a node is close).
function mount.suppress(seconds)
    local t = now() + (seconds or 10)
    if t > suppress_until then suppress_until = t end
end

function mount.reset()
    blocked_until, suppress_until, tries, pending_at, last_shift = 0, 0, 0, nil, 0
end

---@return boolean true while a mount / shift is being cast (the caller should
---stand still and give up the tick).
function mount.tick(player, enabled)
    local t = now()
    if safe(function() return player:is_mounted() end) == true then
        tries, pending_at = 0, nil
        return false
    end
    if pending_at then
        if (t - pending_at) < VERIFY then return true end
        pending_at = nil
        tries = tries + 1
        if tries >= 5 then
            tries = 0
            blocked_until = t + 15
        end
    end
    if not enabled or t < blocked_until or t < suppress_until then return false end

    local level = safe(function() return player:get_level() end) or 0
    local class_id = safe(function() return player:get_class() end)
    local travel_form = spellbook.family("Travel Form")

    if class_id == CLASS_WARLOCK and level <= 40 then blocked_until = t + 120 return false end
    if class_id == CLASS_DRUID and not travel_form then blocked_until = t + 120 return false end
    if level < 30 then return false end

    if safe(function() return player:is_ghost() end) == true then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    if safe(function() return core.character.is_swimming() end) == true then return false end
    if safe(function() return player:is_outdoors() end) == false then return false end
    if safe(function() return player:is_channeling_or_casting() end) == true then return true end

    -- Druid: Travel Form, never a mount.
    if travel_form then
        if has_aura_named(player, "Travel Form") or (t - last_shift) < 1 then return false end
        local sp = izi.spell(travel_form.id)
        if sp and safe(function() return sp:cast_safe(player, "MF gather travel form") end) == true then
            last_shift = t
        end
        return false
    end

    local index = usable_mount_index()
    if not index then
        if class_id ~= CLASS_WARLOCK and class_id ~= CLASS_DRUID then blocked_until = t + 120 end
        return false
    end
    -- A mount cast fails on the move: ask the caller to stop first (it stops
    -- movement while this returns true), then cast once standing.
    if safe(function() return player:is_moving() end) == true then return true end
    pcall(function() core.input.mount(index) end)
    pending_at = t
    return true
end

return mount
