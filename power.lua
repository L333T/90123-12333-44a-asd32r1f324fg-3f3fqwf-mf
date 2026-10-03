-- ============================================================================
-- Master Farmer - Grindbot
-- Mana, read the same way everywhere
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.210.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY (2.202.0). Every module read mana through the izi extensions
-- (mana_max / mana_current / mana_pct). On WoW Forever they gave nothing for a
-- Mage: resting decided the character had no mana ("MP 100 (drink at 0)") and
-- never drank. These try izi first and fall back to the native game_object
-- calls get_max_power / get_power with Enum.PowerType.Mana (0).
-- ============================================================================

local power = {}

local MANA = 0               -- Enum.PowerType.Mana

local function method(unit, name)
    local ok, f = pcall(function() return unit[name] end)
    if ok and type(f) == "function" then return f end
    return nil
end

local function num(fn, unit, a)
    if not fn then return nil end
    local ok, v = pcall(fn, unit, a)
    if ok and type(v) == "number" and v == v and v > -1e9 and v < 1e9 then
        return v
    end
    return nil
end

--- Maximum mana, or nil when no reading works. 0 means "no mana bar".
function power.mana_max(unit)
    if not unit then return nil end
    local v = num(method(unit, "mana_max"), unit)
    if v and v > 0 then return v end
    local n = num(method(unit, "get_max_power"), unit, MANA)
    if n and n > 0 then return n end
    return v or n
end

--- Current mana, or nil.
function power.mana_current(unit)
    if not unit then return nil end
    local mx = power.mana_max(unit)
    local v = num(method(unit, "mana_current"), unit)
    if v and (v > 0 or not mx or mx <= 0) then return v end
    local n = num(method(unit, "get_power"), unit, MANA)
    if n then return n end
    return v
end

--- Mana percent 0-100. 100 when the unit has no mana bar or nothing reads.
function power.mana_pct(unit)
    if not unit then return 100 end
    local mx = power.mana_max(unit)
    if mx and mx <= 0 then return 100 end
    local cur = power.mana_current(unit)
    if cur and mx and mx > 0 then
        local p = cur / mx * 100
        if p < 0 then p = 0 elseif p > 100 then p = 100 end
        return p
    end
    local p = num(method(unit, "mana_pct"), unit)
    if p then
        if p >= 0 and p <= 1.5 then p = p * 100 end
        return p
    end
    return 100
end

--- Does the unit use mana?
function power.has_mana(unit)
    local mx = power.mana_max(unit)
    return type(mx) == "number" and mx > 0
end

return power
