-- ============================================================================
-- Master Farmer - Grindbot
-- gather/esp.lua - herb / ore node ESP and the node cache the detours use
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.9.1
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- After the Sylvanas object-ESP example (Voltz): an O(1) lookup table of node
-- ids / names, a cache refreshed every CACHE_S on the UPDATE tick
-- (core.object_manager.get_all_objects, numeric for loops), and a render pass
-- that only draws what the cache holds (core.graphics.text_3d / circle_3d).
-- Differences from the example, on purpose:
--   - no `goto` (the client's Lua version is not confirmed - AGENTS.md);
--   - the render pass reads NO game object: names and positions are copied
--     into the cache on the update tick (the 3.0.0 render-path rule);
--   - the lookup is the herbing / mining database: gather/nodes.lua (EP ids,
--     names, skill windows) + data/gather_db.lua zones (names by kind).
-- Each entry knows its kind ("herb" / "ore") and whether this character can
-- gather it now (the profession known, rank >= the node's min rank, not
-- looted / blacklisted, can_be_used not false). esp.nearest serves the
-- recorded-path detours (gather/detour.lua).
-- ============================================================================

local M = {}

M.CACHE_S = 0.5               -- s between two object scans (the example's 500 ms)
M.MAX_RANGE = 150             -- yd: nodes farther than this are not cached
local PROF_S = 5              -- s between two profession rank reads
local TEXT_SIZE, TEXT_FONT = 12, 10
local TEXT_Z = 0.6            -- yd above the node for its label
local MAX_DRAW = 60

-- ----------------------------------------------------------------------------
-- the database: by_id / by_name -> { kind, min_rank }
-- ----------------------------------------------------------------------------
local by_id, by_name, any_id = nil, nil, nil
local contains, contains_memo = {}, {}     -- 3.9.1: { base, kind } of match = "contains" zones

local function put(map, key, kind, min_rank)
    if key == nil or key == "" then return end
    local cur = map[key]
    if not cur or min_rank < cur.min_rank then map[key] = { kind = kind, min_rank = min_rank } end
end

local function build_db()
    by_id, by_name, any_id = {}, {}, {}
    contains, contains_memo = {}, {}
    local okn, nodes = pcall(require, "gather/nodes")
    if okn and type(nodes) == "table" then
        for kind, rows in pairs({ herb = nodes.herbs or {}, ore = nodes.ore or {} }) do
            for i = 1, #rows do
                local r = rows[i]
                local mr = tonumber(r.min_rank) or 0
                if type(r.id) == "number" then put(by_id, r.id, kind, mr) end
                if type(r.name) == "string" then put(by_name, r.name, kind, mr) end
            end
        end
    end
    local okd, db = pcall(require, "data/gather_db")
    if okd and type(db) == "table" then
        for _, z in ipairs(db.zones or {}) do
            if z.match == "contains" then
                for _, n in ipairs(z.herbs or {}) do contains[#contains + 1] = { base = n, kind = "herb" } end
                for _, n in ipairs(z.ore or {}) do contains[#contains + 1] = { base = n, kind = "ore" } end
            end
            for _, n in ipairs(z.herbs or {}) do put(by_name, n, "herb", 0) end
            for _, n in ipairs(z.ore or {}) do put(by_name, n, "ore", 0) end
            for _, id in ipairs(z.node_ids or {}) do any_id[id] = true end
        end
    end
end

--- kind, min_rank of an object from its id / name, or nil.
function M.classify(id, name)
    if not by_id then build_db() end
    local row = (type(id) == "number" and by_id[id]) or (type(name) == "string" and by_name[name]) or nil
    if row then return row.kind, row.min_rank end
    -- 3.9.1: a name containing a "contains" zone's base name (memoized per name)
    if type(name) == "string" and name ~= "" and #contains > 0 then
        local m = contains_memo[name]
        if m == nil then
            m = false
            for i = 1, #contains do
                if name:find(contains[i].base, 1, true) then m = contains[i].kind break end
            end
            contains_memo[name] = m
        end
        if m then return m, 0 end
    end
    return nil
end

--- Is `id` listed by a zone profile (kind decided by the name)?
function M.zone_id(id)
    if not by_id then build_db() end
    return any_id[id] == true
end

function M.db_counts()
    if not by_id then build_db() end
    local h, o = 0, 0
    for _, r in pairs(by_name) do if r.kind == "herb" then h = h + 1 else o = o + 1 end end
    local ids = 0
    for _ in pairs(any_id) do ids = ids + 1 end
    for _ in pairs(by_id) do ids = ids + 1 end
    return h, o, ids
end

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------
local function call(o, method, ...)
    local fn = o and o[method]
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, o, ...)
    if ok then return v end
    return nil
end

local function now()
    local ok, t = pcall(core.time)
    return (ok and type(t) == "number") and t or 0
end

local function scan_mod()
    local ok, s = pcall(require, "gather/scan")
    return ok and type(s) == "table" and s or nil
end

-- profession ranks (professions.lua: skill lines on Classic / TBC / Forever,
-- profession tabs on Retail), read every PROF_S
local prof = { t = -1e9, herb = nil, mine = nil }
local function ranks()
    local t = now()
    if t - prof.t < PROF_S then return prof.herb, prof.mine end
    prof.t = t
    prof.herb, prof.mine = nil, nil
    local okp, P = pcall(require, "professions")
    if okp and type(P) == "table" and type(P.known) == "function" then
        local okh, kh, rh = pcall(P.known, "herbalism")
        if okh and kh then prof.herb = tonumber(rh) or 0 end
        local okm, km, rm = pcall(P.known, "mining")
        if okm and km then prof.mine = tonumber(rm) or 0 end
    end
    return prof.herb, prof.mine
end
M._ranks = ranks

-- ----------------------------------------------------------------------------
-- the cache (update tick)
-- ----------------------------------------------------------------------------
local cache = { t = -1e9, list = {}, by_guid = {} }
M.stats = { scans = 0 }

--- Refresh the node cache, at most every CACHE_S. `force` skips the gap.
function M.update(player, force)
    local t = now()
    if not force and (t - cache.t) < M.CACHE_S then return cache.list end
    cache.t = t
    local list, by_guid = {}, {}
    local me = player and call(player, "get_position")
    local ok, objects = pcall(core.object_manager.get_all_objects)
    if not ok or type(objects) ~= "table" then
        cache.list, cache.by_guid = list, by_guid
        return list
    end
    M.stats.scans = M.stats.scans + 1
    if not by_id then build_db() end
    local herb_rank, mine_rank = ranks()
    local S = scan_mod()
    for i = 1, #objects do
        local o = objects[i]
        if o and call(o, "is_valid") == true and call(o, "is_unit") ~= true then
            local id = call(o, "get_npc_id")
            local name = call(o, "get_name")
            local kind, min_rank = M.classify(id, name)
            if kind then
                local p = call(o, "get_position")
                if type(p) == "table" and type(p.x) == "number" then
                    local d = me and math.sqrt((p.x - me.x) ^ 2 + (p.y - me.y) ^ 2 + ((p.z or 0) - (me.z or 0)) ^ 2) or 0
                    if d <= M.MAX_RANGE then
                        local guid = call(o, "get_guid")
                        guid = guid ~= nil and tostring(guid) or nil
                        local rank = (kind == "herb") and herb_rank or mine_rank
                        local skipped = S and guid and S.is_skipped(guid) or false
                        local usable = call(o, "can_be_used") ~= false
                        local e = {
                            obj = o, guid = guid, kind = kind, name = tostring(name or kind), id = id,
                            x = p.x, y = p.y, z = p.z or 0, dist = d,
                            known = rank ~= nil, min_rank = min_rank,
                            gatherable = rank ~= nil and rank >= min_rank and usable and not skipped,
                        }
                        list[#list + 1] = e
                        if guid then by_guid[guid] = e end
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    cache.list, cache.by_guid = list, by_guid
    return list
end

function M.list() return cache.list end
function M.get(guid) return guid and cache.by_guid[guid] or nil end
function M.age() return now() - cache.t end

--- The nearest gatherable node within `range` yd of `pos` (cached data).
--- `want` = { herb = bool, ore = bool } (nil = both).
function M.nearest(pos, range, want)
    if type(pos) ~= "table" then return nil end
    local best, best_d = nil, (range or 50) + 0.001
    local list = cache.list
    for i = 1, #list do
        local e = list[i]
        if e.gatherable and (not want or want[e.kind]) then
            local d = math.sqrt((e.x - pos.x) ^ 2 + (e.y - pos.y) ^ 2 + (e.z - (pos.z or 0)) ^ 2)
            if d < best_d then best, best_d = e, d end
        end
    end
    return best, best and best_d or nil
end

-- ----------------------------------------------------------------------------
-- drawing (render pass: cached data only)
-- ----------------------------------------------------------------------------
local colors = nil
local vec3 = nil
local function draw_kit()
    if colors then return true end
    local okc, color = pcall(require, "common/color")
    local okv, v = pcall(require, "common/geometry/vector_3")
    if not okc or not okv or type(color) ~= "table" or type(v) ~= "table" then return false end
    vec3 = v
    colors = {
        herb = color.new(90, 220, 90, 230),
        ore = color.new(235, 160, 60, 230),
        dim = color.new(150, 150, 150, 160),
        ring = color.new(255, 255, 255, 120),
    }
    return true
end

M.stats.draws = 0
function M.draw()
    local list = cache.list
    if #list == 0 or not draw_kit() then return end
    local n = math.min(#list, MAX_DRAW)
    for i = 1, n do
        local e = list[i]
        local col = e.gatherable and colors[e.kind] or colors.dim
        local label = string.format("%s  %.0f yd%s", e.name, e.dist,
            e.gatherable and "" or (e.known and "" or "  (no " .. (e.kind == "herb" and "Herbalism" or "Mining") .. ")"))
        pcall(core.graphics.text_3d, label, vec3.new(e.x, e.y, e.z + TEXT_Z), TEXT_SIZE, col, true, TEXT_FONT)
        pcall(core.graphics.circle_3d, vec3.new(e.x, e.y, e.z), 1.0, col, 2.0, 1.0)
        M.stats.draws = M.stats.draws + 1
    end
end

function M.reset()
    cache.t, cache.list, cache.by_guid = -1e9, {}, {}
    prof.t = -1e9
end

return M
