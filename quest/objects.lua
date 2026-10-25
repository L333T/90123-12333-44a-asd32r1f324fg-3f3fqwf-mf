-- ============================================================================
-- restedXP_questing
-- quest/objects.lua - quest game objects by id (data/quest_objects.lua)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.20.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.5.0 (user: "create tables with the object IDs that are needed to be
-- interacted with in game to complete quests ... path the player to the
-- object to interact with it"). data/quest_objects.lua (tools/
-- gen_quest_objects.py, from Zygor's TBC Anniversary guides) maps each quest
-- to the object ids its steps click: M.by_quest (objectives), M.givers
-- (objects that give / take the quest, a Wanted Poster).
--
-- The scan follows the Project Sylvanas Object ESP example: one lookup table
-- of every quest object id (O(1) by get_npc_id), core.object_manager.
-- get_all_objects() walked with a numeric for loop at most every CACHE_S s,
-- the matches cached; lookups between scans read the cache and re-check
-- is_valid(). Units are never matched (npc and object ids share numbers).
-- Public: O.objective_ids(goal), O.giver_ids(qid), O.nearest(player, ids,
-- range, skip) -> obj, dist, name; O.name(id); O._reset().
--
-- 4.15.0 OBJECTS BY NAME (user: "Player not interacting with objects to turn
-- in quests"). Zygor writes many object hand-ins with no id ("click Scourge
-- Cauldron" / turnin Target: Dalson's Tears##5219) and the 23:32 log stood at
-- the cauldron: "turnin: at the door, no giver within 40 yd". M.giver_names
-- (the generator's name-only giver clicks) and any name the caller passes
-- (RestedXP's waypoint title, the guide's giver names) are matched against
-- the objects' get_name(), case-insensitive: O.giver_names(qid),
-- O.nearest_named(player, names, range, skip) -> obj, dist, name. Units are
-- never matched; the name scan has its own CACHE_S cache.
-- ============================================================================

local O = {}

O.CACHE_S = 0.5       -- s between two object-list scans (the ESP example's 500 ms)

local data = nil      -- data/quest_objects, or false
local all_ids = nil   -- object id -> true, every id in the tables
local cache = {}      -- game objects whose id is a quest object id
local last_scan = -1e9

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local t = ok and type(izi) == "table" and safe(function() return izi.now() end) or nil
    return type(t) == "number" and t or 0
end

local function load_data()
    if data == nil then
        local ok, m = pcall(require, "data/quest_objects")
        data = (ok and type(m) == "table") and m or false
        all_ids = {}
        if data then
            for _, tbl in ipairs({ data.by_quest or {}, data.givers or {} }) do
                for _, list in pairs(tbl) do
                    for i = 1, #list do all_ids[list[i]] = true end
                end
            end
        end
    end
    return data or nil
end

local function add(set, list)
    if type(list) ~= "table" then return end
    for i = 1, #list do set[list[i]] = true end
end

--- Object ids a goal's objectives are done at: { [id] = true } (may be empty).
function O.objective_ids(goal)
    local d = load_data()
    local set = {}
    if not d or type(goal) ~= "table" then return set end
    local q = tonumber(goal.quest_id)
    if q then add(set, d.by_quest and d.by_quest[q]) end
    local ok, guide = pcall(require, "quest/guide")
    if ok and type(guide) == "table" and type(guide.goal_quest_ids) == "function" then
        local qs = guide.goal_quest_ids(goal)
        for i = 1, #qs do add(set, d.by_quest and d.by_quest[qs[i]]) end
    end
    return set
end

--- Object ids that give / take quest `qid`: { [id] = true } (may be empty).
function O.giver_ids(qid)
    local d = load_data()
    local set = {}
    if d then add(set, d.givers and d.givers[tonumber(qid) or -1]) end
    return set
end

--- Object names that give / take quest `qid` (a list, may be empty).
function O.giver_names(qid)
    local d = load_data()
    local l = d and d.giver_names and d.giver_names[tonumber(qid) or -1]
    return type(l) == "table" and l or {}
end

local named = { t = -1e9, key = nil, list = {} }

--- The nearest non-unit object whose name is one of `names` (case-insensitive)
--- within `range` yd, not in `skip` (guid -> true): obj, distance, name.
function O.nearest_named(player, names, range, skip)
    if type(names) ~= "table" or #names == 0 or not player then return nil end
    local want, parts = {}, {}
    for i = 1, #names do
        local n = type(names[i]) == "string" and string.lower(names[i]) or nil
        if n and n ~= "" then want[n] = true parts[#parts + 1] = n end
    end
    if #parts == 0 then return nil end
    table.sort(parts)
    local key = table.concat(parts, "|")
    local t = now()
    if key ~= named.key or (t - named.t) >= O.CACHE_S then
        named.key, named.t = key, t
        local out = {}
        local list = safe(function() return core.object_manager.get_all_objects() end)
        if type(list) == "table" then
            for i = 1, #list do
                local o = list[i]
                if o and safe(function() return o:is_valid() end) == true
                    and safe(function() return o:is_unit() end) ~= true then
                    local n = safe(function() return o:get_name() end)
                    if type(n) == "string" and want[string.lower(n)] then out[#out + 1] = o end
                end
            end
        end
        named.list = out
    end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local best, bd = nil, nil
    for i = 1, #named.list do
        local o = named.list[i]
        if o and safe(function() return o:is_valid() end) == true
            and not (skip and skip[safe(function() return o:get_guid() end) or false]) then
            local p = safe(function() return o:get_position() end)
            if p then
                local dx, dy, dz = p.x - me.x, p.y - me.y, (p.z or 0) - (me.z or 0)
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d <= (tonumber(range) or 80) and (not bd or d < bd) then best, bd = o, d end
            end
        end
    end
    if not best then return nil end
    return best, bd, tostring(safe(function() return best:get_name() end) or "object")
end

function O.name(id)
    local d = load_data()
    return d and d.names and d.names[id] or nil
end

--- Rebuild the cache from get_all_objects (at most every CACHE_S s).
local function scan()
    local t = now()
    if (t - last_scan) < O.CACHE_S then return end
    last_scan = t
    load_data()
    local list = safe(function() return core.object_manager.get_all_objects() end)
    local out = {}
    if type(list) == "table" then
        for i = 1, #list do
            local o = list[i]
            if o and safe(function() return o:is_valid() end) == true
                and safe(function() return o:is_unit() end) ~= true then
                local id = safe(function() return o:get_npc_id() end)
                if id and all_ids[id] then out[#out + 1] = o end
            end
        end
    end
    cache = out
end

--- The nearest cached object with an id in `ids` within `range` yd, not in
--- `skip` (guid -> true): obj, distance, name.
function O.nearest(player, ids, range, skip)
    if type(ids) ~= "table" or next(ids) == nil or not player then return nil end
    scan()
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local best, bd, bid = nil, nil, nil
    for i = 1, #cache do
        local o = cache[i]
        if o and safe(function() return o:is_valid() end) == true then
            local id = safe(function() return o:get_npc_id() end)
            if id and ids[id] and not (skip and skip[safe(function() return o:get_guid() end) or false]) then
                local p = safe(function() return o:get_position() end)
                if p then
                    local dx, dy, dz = p.x - me.x, p.y - me.y, (p.z or 0) - (me.z or 0)
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d <= range and (not bd or d < bd) then best, bd, bid = o, d, id end
                end
            end
        end
    end
    if not best then return nil end
    local name = safe(function() return best:get_name() end)
    if type(name) ~= "string" or name == "" then name = O.name(bid) or ("object " .. tostring(bid)) end
    return best, bd, name
end

function O._reset()
    data, all_ids, cache, last_scan = nil, nil, {}, -1e9
    named = { t = -1e9, key = nil, list = {} }
end

return O
