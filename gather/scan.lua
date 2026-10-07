-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering: herb / ore node scan (port of EP_Herb_Mine Mine_Herb_Find)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.238.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- The active list is gather/nodes.lua filtered by the current Herbalism and
-- Mining ranks (rows the toggles allow) under the client cap
-- (gather/route.profession_cap). A world object matches a row when its entry
-- id (get_npc_id) equals the row id or its English name equals the row name.
-- Units are never matched. GUIDs that were looted or blacklisted are skipped.
-- ============================================================================

local route = require("gather/route")

local scan = {}

local nodes_data = nil
local active = {}           -- { by_id = { [id] = true }, by_name = { [name] = true } }
local active_key = ""

-- GUID sets. Bounded: oldest entries are dropped past MAX_GUIDS.
local MAX_GUIDS = 400
local blacklist, looted = {}, {}
local blacklist_order, looted_order = {}, {}

local function guid_of(o)
    local ok, g = pcall(function() return o:get_guid() end)
    if ok and g ~= nil and g ~= "" then return tostring(g) end
    return nil
end

local function remember(set, order, guid)
    if not guid or set[guid] then return end
    set[guid] = true
    order[#order + 1] = guid
    if #order > MAX_GUIDS then
        set[table.remove(order, 1)] = nil
    end
end

function scan.blacklist(guid) remember(blacklist, blacklist_order, guid) end
function scan.mark_looted(guid) remember(looted, looted_order, guid) end
function scan.is_skipped(guid) return guid ~= nil and (blacklist[guid] or looted[guid]) == true end

---Rebuilds the active row set when ranks / toggles / cap change.
---@return number active rows
function scan.refresh(need_herb, need_mine)
    nodes_data = nodes_data or require("gather/nodes")
    local herb, mine, has_herb, has_mine = route.ranks()
    need_herb, need_mine = need_herb and has_herb, need_mine and has_mine
    local cap = route.profession_cap()
    local key = string.format("%s%s%d/%d/%d", need_herb and "H" or "-", need_mine and "M" or "-", herb, mine, cap)
    if key == active_key then return active.count or 0 end
    active_key = key
    local by_id, by_name, n = {}, {}, 0
    local function add(rows, rank)
        for i = 1, #rows do
            local r = rows[i]
            if route.window_ok(rank, r.min_rank, r.max_rank, r.max_op, cap) then
                if type(r.id) == "number" then by_id[r.id] = true end
                if type(r.name) == "string" and r.name ~= "" then by_name[r.name] = true end
                n = n + 1
            end
        end
    end
    if need_herb then add(nodes_data.herbs, herb) end
    if need_mine then add(nodes_data.ore, mine) end
    active = { by_id = by_id, by_name = by_name, count = n }
    return n
end

---Does this object match an active row?
local function matches(o)
    local ok_u, is_unit = pcall(function() return o:is_unit() end)
    if ok_u and is_unit == true then return false end
    local ok_i, id = pcall(function() return o:get_npc_id() end)
    if ok_i and type(id) == "number" and active.by_id and active.by_id[id] then return true end
    local ok_n, name = pcall(function() return o:get_name() end)
    return ok_n and type(name) == "string" and active.by_name ~= nil and active.by_name[name] == true
end

---Closest matching node within `range` yards of `pos` (3D), or nil.
---`skip_lists` = false ignores the blacklist / looted sets (the script's
---one-time rescan around a stored point did not filter them).
---@return game_object|nil node, number|nil dist
function scan.closest(pos, range, skip_lists)
    if not pos or not active.count or active.count == 0 then return nil, nil end
    local ok, list = pcall(core.object_manager.get_all_objects)
    if not ok or type(list) ~= "table" then return nil, nil end
    local best, best_d = nil, (range or 200) + 0.001
    for i = 1, #list do
        local o = list[i]
        local okv, valid = pcall(function() return o:is_valid() end)
        if okv and valid == true and matches(o) then
            local usable = true
            local okc, can = pcall(function() return o:can_be_used() end)
            if okc and can == false then usable = false end
            if usable and (skip_lists == false or not scan.is_skipped(guid_of(o))) then
                local okp, op = pcall(function() return o:get_position() end)
                if okp and op then
                    local d = op:dist_to(pos)
                    if d < best_d then best, best_d = o, d end
                end
            end
        end
    end
    if best then return best, best_d end
    return nil, nil
end

scan.guid_of = guid_of

return scan
