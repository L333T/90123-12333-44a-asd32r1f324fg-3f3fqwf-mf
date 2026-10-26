-- ============================================================================
-- Master Farmer - mfdb.lua: the Master Farmer database (shared by the products)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- ============================================================================
-- 2026-10-25 (user: "Create database tables like the ones in these folders and
-- use them in all of the master farmer projects"): the GTFO (Questie-format)
-- TBC database, cut to what the bots use by tools/import_gtfo_db.lua into
-- data/mfdb_quests / _npcs / _objects / _items / _zones. Each data file is ONE
-- string, one tab-separated row per id; a row is split only when it is asked
-- for (and kept in a small cache), so the database costs its text and an index.
-- Source of truth: shared/mfdb/mfdb.lua - tools/sync_mfdb.py copies it (and the
-- data) into every product. Pure Lua + documented Core calls only (map -> world
-- conversion: core.game_ui.get_world_pos_from_map_pos, pcall'd), no rays.
--
--   D.quest(id)   { name, req, level, races, classes, start_npcs, start_objs,
--                   start_items, end_npcs, end_objs, obj_npcs, obj_objs, obj_items,
--                   kill_credit, source_item, req_items, pre_group, pre_single,
--                   zone, next, exclusive, special, texts = { ["n17998"] = text } }
--   D.npc(id)     { name, min, max, rank, friendly ("A" / "H" / "AH" / "-"),
--                   flags, sub, spawns = { {map, x, y}, ... }, starts, ends }
--   D.object(id)  { name, spawns, starts, ends }
--   D.item(id)    { name, npc_drops, obj_drops, start_quest, food_type, req_level,
--                   class, subclass, vendors, related }
--   D.services(mask, side)    service NPCs (D.F flags) for a side: rows
--                             { npc_id, name, side, map, x, y, flags, sub }
--   D.world(map, x, y)        world x, y and continent of a map point (x / y 0-100)
--   D.nearest(kind, id, x, y, cont, max)  the nearest spawn of an npc / object on
--                             continent `cont`: wx, wy, distance
--   D.item_quests(id)         { use = set, starts = set, wanted = set } for an item
--   D.objective_ids(qid)      npcs (objectives + kill credit), objects, items: sets
--   D.services_world(mask, side, cont, cont_of_map)  2026-10-26: the service spawns as
--                             WORLD points on continent `cont` - list, done. Built a slice
--                             per frame; use the list only when done.
--
-- FRAME BUDGETS (2026-10-26, user: "Game freezing on NPC interaction"): the first
-- repairer / flight master search converted EVERY spawn of the database (1250 + 100,
-- RestedXP 1356, Auto BG 603) with core.game_ui.get_world_pos_from_map_pos in ONE frame.
-- Now: a spawn on another continent (cont_of_map, a plain table lookup) is never
-- converted, at most FRAME_CONV conversions and FRAME_ROWS row scans happen per frame
-- (shared by every caller), and the quest <-> item index is built a slice per frame.
-- ============================================================================

local D = {}

-- npcFlags (TBC)
D.F = {
    GOSSIP = 0x1, QUESTGIVER = 0x2, TRAINER = 0x10, CLASS_TRAINER = 0x20, PROF_TRAINER = 0x40,
    VENDOR = 0x80, AMMO = 0x100, FOOD = 0x200, POISON = 0x400, REAGENT = 0x800, REPAIR = 0x1000,
    FLIGHT = 0x2000, SPIRIT_HEALER = 0x4000, INNKEEPER = 0x10000, BANKER = 0x20000,
    BATTLEMASTER = 0x100000, STABLE = 0x400000,
}

local bitlib = (type(bit) == "table" and bit) or (type(bit32) == "table" and bit32) or nil
local function has_flag(v, f)
    if bitlib then return bitlib.band(v, f) ~= 0 end
    return math.floor(v / f) % 2 == 1
end
D.has_flag = has_flag

local function safe(fn, ...)
    local ok, v, w = pcall(fn, ...)
    if ok then return v, w end
    return nil
end

-- ----------------------------------------------------------------------------
-- rows
-- ----------------------------------------------------------------------------
local index = {}               -- kind -> id -> row string
local cache = {}               -- kind -> id -> parsed (false = none)
local cache_n = {}
local CACHE_MAX = 1500

local function rows(kind)
    local ix = index[kind]
    if ix then return ix end
    ix = {}
    local ok, src = pcall(require, "data/mfdb_" .. kind)
    if ok and type(src) == "string" then
        for line in src:gmatch("[^\n]+") do
            local id = tonumber(line:match("^(%d+)\t"))
            if id then ix[id] = line end
        end
    end
    index[kind] = ix
    return ix
end
D._rows = rows

-- per-frame budgets, shared by every caller (a frame = one core.time() value)
D.FRAME_ROWS, D.FRAME_CONV = 800, 40
local frame = { t = -1, rows = 0, conv = 0 }
local function clock()
    local ok, t = pcall(function() return core.time() end)
    return (ok and type(t) == "number") and t or 0
end
local function budget(kind)
    local t = clock()
    if t ~= frame.t then frame.t, frame.rows, frame.conv = t, 0, 0 end
    if kind == "conv" then
        if frame.conv >= D.FRAME_CONV then return false end
        frame.conv = frame.conv + 1
        return true
    end
    if frame.rows >= D.FRAME_ROWS then return false end
    frame.rows = frame.rows + 1
    return true
end
D._budget, D._frame = budget, frame

local id_arrays = {}
--- The ids of a kind as an array (slices walk it by position).
local function id_array(kind)
    local a = id_arrays[kind]
    if a then return a end
    a = {}
    for id in pairs(rows(kind)) do a[#a + 1] = id end
    table.sort(a)
    id_arrays[kind] = a
    return a
end

local function split(line)
    local out, n = {}, 0
    for f in (line .. "\t"):gmatch("([^\t]*)\t") do
        n = n + 1
        out[n] = f
    end
    return out
end

local function ids(s)
    local out = {}
    if s and s ~= "" then
        for v in s:gmatch("%d+") do out[#out + 1] = tonumber(v) end
    end
    return out
end

local function spawns(s)
    local out = {}
    if not s or s == "" then return out end
    for zone in s:gmatch("[^;]+") do
        local map, pts = zone:match("^(%d+):(.*)$")
        map = tonumber(map)
        if map then
            for x, y in pts:gmatch("([%d%.]+),([%d%.]+)") do
                out[#out + 1] = { map = map, x = tonumber(x), y = tonumber(y) }
            end
        end
    end
    return out
end
D._spawns = spawns

local PARSE = {
    quests = function(f)
        local texts = {}
        for k, v in (f[24] or ""):gmatch("([nokci]%d+)=([^;]*)") do texts[k] = v end
        return {
            id = tonumber(f[1]), name = f[2], req = tonumber(f[3]) or 0, level = tonumber(f[4]) or 0,
            races = tonumber(f[5]) or 0, classes = tonumber(f[6]) or 0,
            start_npcs = ids(f[7]), start_objs = ids(f[8]), start_items = ids(f[9]),
            end_npcs = ids(f[10]), end_objs = ids(f[11]),
            obj_npcs = ids(f[12]), obj_objs = ids(f[13]), obj_items = ids(f[14]), kill_credit = ids(f[15]),
            source_item = tonumber(f[16]) or 0, req_items = ids(f[17]),
            pre_group = ids(f[18]), pre_single = ids(f[19]), zone = tonumber(f[20]) or 0,
            next = tonumber(f[21]) or 0, exclusive = ids(f[22]), special = tonumber(f[23]) or 0, texts = texts,
        }
    end,
    npcs = function(f)
        return {
            id = tonumber(f[1]), name = f[2], min = tonumber(f[3]) or 0, max = tonumber(f[4]) or 0,
            rank = tonumber(f[5]) or 0, friendly = f[6] or "-", flags = tonumber(f[7]) or 0, sub = f[8] or "",
            spawns = spawns(f[9]), starts = ids(f[10]), ends = ids(f[11]),
        }
    end,
    objects = function(f)
        return { id = tonumber(f[1]), name = f[2], spawns = spawns(f[3]), starts = ids(f[4]), ends = ids(f[5]) }
    end,
    items = function(f)
        return {
            id = tonumber(f[1]), name = f[2], npc_drops = ids(f[3]), obj_drops = ids(f[4]),
            start_quest = tonumber(f[5]) or 0, food_type = tonumber(f[6]) or 0, req_level = tonumber(f[7]) or 0,
            class = tonumber(f[8]) or 0, subclass = tonumber(f[9]) or 0, vendors = ids(f[10]), related = ids(f[11]),
        }
    end,
}

local function get(kind, id)
    id = tonumber(id)
    if not id then return nil end
    local c = cache[kind]
    if not c then
        c = {}
        cache[kind], cache_n[kind] = c, 0
    end
    local v = c[id]
    if v ~= nil then return v or nil end
    local line = rows(kind)[id]
    v = line and PARSE[kind](split(line)) or false
    if cache_n[kind] >= CACHE_MAX then c, cache_n[kind] = {}, 0 cache[kind] = c end
    c[id] = v
    cache_n[kind] = cache_n[kind] + 1
    return v or nil
end

function D.quest(id) return get("quests", id) end
function D.npc(id) return get("npcs", id) end
function D.object(id) return get("objects", id) end
function D.item(id) return get("items", id) end
function D.available() return next(rows("quests")) ~= nil end

-- ----------------------------------------------------------------------------
-- map -> world
-- ----------------------------------------------------------------------------
local vec2_mod = nil
local world_cache, world_n = {}, 0
--- World x, y and continent (instance map) of map point x / y (0-100). nil when
--- the client cannot convert it.
function D.world(map, x, y)
    local k = map .. ":" .. x .. ":" .. y
    local w = world_cache[k]
    if w ~= nil then
        if not w then return nil end
        return w[1], w[2], w[3]
    end
    if vec2_mod == nil then
        local ok, m = pcall(require, "common/geometry/vector_2")
        vec2_mod = (ok and type(m) == "table") and m or false
    end
    local wx, wy, cont = nil, nil, nil
    if vec2_mod and core and core.game_ui and type(core.game_ui.get_world_pos_from_map_pos) == "function" then
        local v = vec2_mod.new(x / 100, y / 100)
        local p, c = safe(core.game_ui.get_world_pos_from_map_pos, map, v)
        if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and (p.x ~= 0 or p.y ~= 0) then
            wx, wy, cont = p.x, p.y, tonumber(c)
        end
    end
    if world_n > 4000 then world_cache, world_n = {}, 0 end
    world_cache[k] = wx and { wx, wy, cont } or false
    world_n = world_n + 1
    return wx, wy, cont
end

--- The nearest spawn of an npc / object (kind "npc" / "object") to world x, y on
--- continent `cont` (nil = any): wx, wy, distance - or nil.
function D.nearest(kind, id, x, y, cont, max)
    local rec = (kind == "object") and D.object(id) or D.npc(id)
    if not rec then return nil end
    local best, bx, by = nil, nil, nil
    for _, s in ipairs(rec.spawns) do
        local wx, wy, c = D.world(s.map, s.x, s.y)
        if wx and (cont == nil or c == nil or c == cont) then
            local d = math.sqrt((wx - x) ^ 2 + (wy - y) ^ 2)
            if (not max or d <= max) and (best == nil or d < best) then best, bx, by = d, wx, wy end
        end
    end
    if not best then return nil end
    return bx, by, best
end

-- ----------------------------------------------------------------------------
-- services
-- ----------------------------------------------------------------------------
local svc_cache = {}
--- Service NPCs carrying any flag of `mask`, friendly to `side` ("A" / "H";
--- nil = both): rows { npc_id, name, side ("A" / "H" / "B"), map, x, y, flags, sub }
--- (one row per spawn).
function D.services(mask, side)
    local key = tostring(mask) .. ":" .. tostring(side)
    if svc_cache[key] then return svc_cache[key] end
    local out = {}
    for id, line in pairs(rows("npcs")) do
        local fl = tonumber(line:match("^%d+\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t(%d+)\t"))
        if fl and has_flag(fl, mask) then
            local n = D.npc(id)
            if n then
                local fr = n.friendly
                local s = (fr == "AH") and "B" or fr
                if s ~= "-" and (side == nil or s == "B" or s == side) then
                    for _, sp in ipairs(n.spawns) do
                        out[#out + 1] = { npc_id = id, name = n.name, side = s, map = sp.map, x = sp.x / 100,
                            y = sp.y / 100, flags = n.flags, sub = n.sub }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.npc_id < b.npc_id end)
    svc_cache[key] = out
    return out
end

-- ----------------------------------------------------------------------------
-- quests <-> items
-- ----------------------------------------------------------------------------
local item_q, item_job = nil, nil
local EMPTY_IQ = { use = {}, starts = {}, wanted = {} }
local function iq_add(i, kind, q)
    if not i or i <= 0 then return end
    local e = item_q[i]
    if not e then e = { use = {}, starts = {}, wanted = {} } item_q[i] = e end
    e[kind][q] = true
end
--- One budgeted slice of the quest <-> item index. True when it is complete.
local function item_index_step()
    if item_job and item_job.done then return true end
    if not item_job then
        item_q = {}
        item_job = { stage = "quests", i = 0, list = id_array("quests"), done = false }
    end
    local j = item_job
    if j.stage == "quests" then
        local qrows = rows("quests")
        while j.i < #j.list do
            if not budget("rows") then return false end
            j.i = j.i + 1
            local qid = j.list[j.i]
            local f = split(qrows[qid])
            iq_add(tonumber(f[16]), "use", qid)
            for _, i in ipairs(ids(f[17])) do iq_add(i, "use", qid) end
            for _, i in ipairs(ids(f[9])) do iq_add(i, "starts", qid) end
            for _, i in ipairs(ids(f[14])) do iq_add(i, "wanted", qid) end
        end
        j.stage, j.i, j.list = "items", 0, id_array("items")
    end
    local irows = rows("items")
    while j.i < #j.list do
        if not budget("rows") then return false end
        j.i = j.i + 1
        local iid = j.list[j.i]
        local sq = tonumber(irows[iid]:match("^%d+\t[^\t]*\t[^\t]*\t[^\t]*\t(%d+)\t"))
        if sq and sq > 0 then iq_add(iid, "starts", sq) end
    end
    j.done = true
    return true
end
D._item_index_step = item_index_step

--- What quests an item serves: { use = set (source / required items),
--- starts = set (it starts the quest), wanted = set (an objective) }. While the
--- index is still being built (a slice a frame) every item answers empty.
function D.item_quests(item_id)
    if not item_index_step() then return EMPTY_IQ end
    return item_q[tonumber(item_id) or -1] or EMPTY_IQ
end
function D.item_index_ready() return item_job ~= nil and item_job.done == true end

-- ----------------------------------------------------------------------------
-- services as world points, built a slice per frame (2026-10-26)
-- ----------------------------------------------------------------------------
local sw_jobs = {}
--- Service spawns (D.F `mask`, side "A" / "H" / nil) as world points on continent
--- `cont`: list of { cont, npc, x, y, side, name, flags, sub }, done. A spawn whose UI
--- map is on another continent (cont_of_map(map), when given) is never converted.
--- Each call goes on where the last stopped, within the frame budgets.
function D.services_world(mask, side, cont, cont_of_map)
    local key = tostring(mask) .. ":" .. tostring(side) .. ":" .. tostring(cont)
    local j = sw_jobs[key]
    if not j then
        j = { stage = "scan", i = 0, list = id_array("npcs"), cand = {}, k = 0, out = {}, done = false }
        sw_jobs[key] = j
    end
    if j.done then return j.out, true end
    local nrows = rows("npcs")
    if j.stage == "scan" then
        while j.i < #j.list do
            if not budget("rows") then return j.out, false end
            j.i = j.i + 1
            local id = j.list[j.i]
            local line = nrows[id]
            local fl = tonumber(line:match("^%d+\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t(%d+)\t"))
            if fl and has_flag(fl, mask) then
                local n = PARSE.npcs(split(line))
                local s0 = (n.friendly == "AH") and "B" or n.friendly
                if s0 ~= "-" and (side == nil or s0 == "B" or s0 == side) then
                    for _, sp in ipairs(n.spawns) do
                        local mc = type(cont_of_map) == "function" and cont_of_map(sp.map) or nil
                        if mc == nil or cont == nil or mc == cont then
                            j.cand[#j.cand + 1] = { npc = id, name = n.name, side = s0, map = sp.map, x = sp.x, y = sp.y,
                                flags = n.flags, sub = n.sub }
                        end
                    end
                end
            end
        end
        j.stage = "conv"
    end
    while j.k < #j.cand do
        if not budget("conv") then return j.out, false end
        j.k = j.k + 1
        local c = j.cand[j.k]
        local wx, wy, wc = D.world(c.map, c.x, c.y)
        if wx and (cont == nil or wc == nil or wc == cont) then
            j.out[#j.out + 1] = { cont = wc or cont, npc = c.npc, x = wx, y = wy, side = c.side, name = c.name,
                flags = c.flags, sub = c.sub }
        end
    end
    j.done, j.cand = true, nil
    return j.out, true
end

--- A quest's objective ids: npcs (objectives + kill credit), objects, items (sets).
function D.objective_ids(qid)
    local q = D.quest(qid)
    local n, o, i = {}, {}, {}
    if q then
        for _, v in ipairs(q.obj_npcs) do n[v] = true end
        for _, v in ipairs(q.kill_credit) do n[v] = true end
        for _, v in ipairs(q.obj_objs) do o[v] = true end
        for _, v in ipairs(q.obj_items) do i[v] = true end
    end
    return n, o, i
end

--- The objective (npc / object / item) whose text is `text` in quest `qid`:
--- kind ("n" npc, "o" object, "i" item, "k" kill credit), id - or nil.
function D.objective_by_text(qid, text)
    local q = D.quest(qid)
    if not q or type(text) ~= "string" then return nil end
    local want = text:lower():gsub("[:%d/%s]+$", "")
    for k, v in pairs(q.texts) do
        local t = v:lower()
        if t == want or want:find(t, 1, true) == 1 then return k:sub(1, 1), tonumber(k:sub(2)) end
    end
    return nil
end

function D.reset()
    index, cache, cache_n, world_cache, world_n, svc_cache, item_q = {}, {}, {}, {}, 0, {}, nil
    id_arrays, item_job, sw_jobs = {}, nil, {}
end

return D
