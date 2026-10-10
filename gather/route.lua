-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering: client skill cap, profession ranks, route selection
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.269.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Port of EP_Herb_Mine Path_Information(): walk gather/routes.lua in FILE
-- ORDER and take the first row whose faction, profession toggle and rank
-- window match. Mining rows come first, so a character with both professions
-- at 0 takes the mining route, as the script did.
--
-- Client cap (PORT_PLAYBOOK "Skill cap by client"): 375 on "Tbc", 300 on
-- everything else ("Vanilla" = Classic, "Forever"). A route or node row is
-- eligible only when its min_rank is below the cap, so the Hellfire rows
-- (min 300) never run on Classic or Forever.
--
-- Source defect kept on purpose: the two herbalism_300_375 rows compare the
-- MINING rank against max_rank (max_stat = "mining"), because the script wrote
-- `HR >= 300 and MR <= 375`.
-- ============================================================================

local factions = require("data/factions")

local route = {}

local routes_data = nil

local function data()
    if not routes_data then routes_data = require("gather/routes") end
    return routes_data
end

---@return number 375 on TBC Anniversary, 300 on Classic ("Vanilla") and Forever.
function route.profession_cap()
    local ok, version = pcall(core.get_game_version)
    if ok and version == "Tbc" then
        return 375
    end
    return 300
end

---Herbalism and Mining skill levels (0 when the profession is not learned).
---Professions are matched by their English skill-line name.
---@return number herb, number mine, boolean has_herb, boolean has_mine
function route.ranks()
    local herb, mine, has_herb, has_mine = 0, 0, false, false
    local ok, profs = pcall(core.spell_book.get_professions)
    if not ok or type(profs) ~= "table" then return herb, mine, has_herb, has_mine end
    for _, slot in ipairs({ "prof1", "prof2" }) do
        local index = profs[slot]
        if type(index) == "number" then
            local ok2, info = pcall(core.spell_book.get_profession_info, index)
            if ok2 and type(info) == "table" then
                local name = tostring(info.skill_line_name or "")
                local level = tonumber(info.skill_level) or 0
                if name == "Herbalism" then herb, has_herb = level, true end
                if name == "Mining" then mine, has_mine = level, true end
            end
        end
    end
    return herb, mine, has_herb, has_mine
end

---`max_op` comparison, with max_rank clamped to the client cap.
local function max_ok(rank, max_rank, op, cap)
    local m = math.min(tonumber(max_rank) or cap, cap)
    if op == "<" then return rank < m end
    return rank <= m
end

---Is a node/route rank window open at `rank` on this client?
---@return boolean
function route.window_ok(rank, min_rank, max_rank, op, cap)
    cap = cap or route.profession_cap()
    min_rank = tonumber(min_rank) or 0
    if min_rank >= cap then return false end
    if rank < min_rank then return false end
    return max_ok(rank, max_rank, op, cap)
end

---First matching route, or nil plus a reason.
---@param player game_object
---@param need_mine boolean Mining toggle on the Gathering tab
---@param need_herb boolean Herbalism toggle on the Gathering tab
---@return table|nil route, string reason
function route.select(player, need_mine, need_herb)
    local side = factions.of_player(player)
    if not side then return nil, "faction unreadable" end
    local faction = side == factions.HORDE and "Horde" or "Alliance"
    local cap = route.profession_cap()
    local herb, mine, has_herb, has_mine = route.ranks()
    -- Only a learned profession picks a route (gather/trainer teaches it first).
    need_herb, need_mine = need_herb and has_herb, need_mine and has_mine
    local rank_of = { herbalism = herb, mining = mine }
    local rows = data()
    for i = 1, #rows do
        local r = rows[i]
        local wanted = (r.gate == "Need_Mine" and need_mine) or (r.gate == "Need_Herb" and need_herb)
        if r.faction == faction and wanted and (tonumber(r.min_rank) or 0) < cap then
            local skill_rank = rank_of[r.skill] or 0
            local max_rank_of = rank_of[r.max_stat or r.skill] or 0
            if skill_rank >= (tonumber(r.min_rank) or 0) and max_ok(max_rank_of, r.max_rank, r.max_op, cap) then
                return r, string.format("%s (herb %d, mine %d, cap %d)", r.id, herb, mine, cap)
            end
        end
    end
    return nil, string.format("no %s route for herb %d / mine %d under cap %d", faction, herb, mine, cap)
end

return route
