-- ============================================================================
-- Master Farmer - Grindbot
-- professions.lua - which professions the character has (Profession API)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.2
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- One place that answers "does this character know <profession>, at what
-- rank", for the quest engine's profession steps and the gathering trainer:
--   1. core.skill skill lines (Classic / TBC / Forever since the 2026-10-06
--      core update): every profession, primary and secondary, by name,
--   2. core.spell_book.get_professions + get_profession_info (prof1, prof2,
--      fishing, cooking, archaeology - no First Aid there),
-- and how many PRIMARY professions are learned
-- (core.trade_skill.get_num_primary_professions; Blizzard's trainer refuses
-- a third primary). Names are matched in lower case ("first aid").
-- ============================================================================

local P = {}

local SECONDARY = { cooking = true, fishing = true, ["first aid"] = true, archaeology = true, riding = true }

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

function P.is_secondary(name)
    return SECONDARY[string.lower(tostring(name or ""))] == true
end

--- From the skill lines: rank, max rank of `name`, or nil.
local function from_skill_lines(name)
    local n = tonumber(safe(function() return core.skill.get_num_skill_lines() end)) or 0
    for i = 1, math.min(n, 200) do
        local info = safe(function() return core.skill.get_skill_line_info(i) end)
        if type(info) ~= "table" then break end
        if info.is_header ~= true and string.lower(tostring(info.name or "")) == name then
            return tonumber(info.skill_rank) or 0, tonumber(info.skill_max_rank) or 0
        end
    end
    return nil
end

--- From the profession spell tabs: rank, max rank of `name`, or nil.
local function from_profession_tabs(name)
    local profs = safe(function() return core.spell_book.get_professions() end)
    if type(profs) ~= "table" then return nil end
    for _, slot in ipairs({ "prof1", "prof2", "fishing", "cooking", "archaeology" }) do
        local idx = profs[slot]
        if type(idx) == "number" then
            local info = safe(function() return core.spell_book.get_profession_info(idx) end)
            if type(info) == "table" then
                local a = string.lower(tostring(info.skill_line_name or ""))
                local b = string.lower(tostring(info.name or ""))
                if a == name or b == name then
                    return tonumber(info.skill_level) or 0, tonumber(info.max_skill_level) or 0
                end
            end
        end
    end
    return nil
end

--- Does the character know profession `name`? known, rank, max_rank.
function P.known(name)
    name = string.lower(tostring(name or ""))
    if name == "" then return false end
    local r, m = from_skill_lines(name)
    if r == nil then r, m = from_profession_tabs(name) end
    if r == nil then return false end
    return true, r, m
end

--- How many primary professions are learned (0, 1, 2), or nil when the
--- client does not answer.
function P.primary_count()
    local n = tonumber(safe(function() return core.trade_skill.get_num_primary_professions() end))
    if n and n > 0 then return n end
    -- 0 can also mean "API unavailable": count the primary profession tabs
    local profs = safe(function() return core.spell_book.get_professions() end)
    if type(profs) == "table" then
        local c = (profs.prof1 and 1 or 0) + (profs.prof2 and 1 or 0)
        if c > 0 then return c end
    end
    return n
end

--- Can `name` be learned at all, as far as the profession limit goes?
--- false + why when two primary professions are already learned.
function P.can_learn(name)
    if P.is_secondary(name) then return true end
    local known = P.known(name)
    if known then return true end
    local n = P.primary_count()
    if type(n) == "number" and n >= 2 then
        return false, "two primary professions are already learned (unlearn one first)"
    end
    return true
end

return P
