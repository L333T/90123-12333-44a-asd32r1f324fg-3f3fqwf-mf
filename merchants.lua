-- ============================================================================
-- Master Farmer - Grindbot
-- merchants.lua - remembered repair NPCs and innkeepers
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.2.0
-- ============================================================================
-- The user (2.318.0): "Grinding path should vendor at repair NPC or INN if
-- bags are full". A grind route without its own merchant record had only the
-- zone merchant table (few zones), a vendor in sight, the Hearthstone and the
-- Alliance Eastern Kingdoms inn list - full bags elsewhere had nowhere to go.
--
-- Every NPC the bot sees that the game flags as a repairer (npc flag 0x1000)
-- or an innkeeper (0x10000) is remembered: npc id, name, position, continent.
-- Scanned every SCAN_EVERY s from the visible objects; kept per continent in
-- scripts_data/mfb/merchants.txt so it survives reloads and sessions.
-- merchants.nearest(player, want_repair) gives the nearest one on the
-- player's continent as a merchant record { npc_id, name, x, y, z } - the
-- shape vendor.lua already walks to and talks to.
-- ============================================================================

local M = {}

local FOLDER = "mfb"
local FILE = FOLDER .. "/merchants.txt"
local NPC_REPAIR, NPC_INNKEEPER = 0x1000, 0x10000
local SCAN_EVERY = 5.0
local SAVE_GAP = 15.0
local MAX_KEEP = 400
local MAX_DIST = 3000          -- yd: farther than this is not "the nearest" any more

M.NPC_REPAIR, M.NPC_INNKEEPER = NPC_REPAIR, NPC_INNKEEPER

local book = {}                -- "cont|npc" -> { cont, npc, x, y, z, repair, inn, name }
local book_n = 0
local loaded = false
local dirty, next_save = false, 0
local next_scan = -1e9

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function now()
    return safe(core.time) or 0
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "merchants", fmt, ...) end
end

local function has_flag(v, bit)
    return type(v) == "number" and v > 0 and math.floor(v / bit) % 2 == 1
end

--- The continent the player is on (0 / 1 / 530), else the raw map id.
local function continent(pos)
    local ok, gv = pcall(require, "gamever")
    if ok and type(gv) == "table" and type(gv.continent_of) == "function" then
        local c, raw = gv.continent_of(pos)
        if c ~= nil then return c end
        if raw ~= nil then return raw end
    end
    return safe(function() return core.get_map_id() end) or -1
end

local function load()
    loaded = true
    local body = safe(function() return core.read_data_file(FILE) end)
    if type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        local cont, npc, x, y, z, rep, inn, name =
            line:match("^(%-?%d+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%d) (%d) (.*)$")
        cont, npc, x, y, z = tonumber(cont), tonumber(npc), tonumber(x), tonumber(y), tonumber(z)
        if cont and npc and x and y and z then
            local key = cont .. "|" .. npc
            if not book[key] then book_n = book_n + 1 end
            book[key] = { cont = cont, npc = npc, x = x, y = y, z = z, repair = rep == "1", inn = inn == "1",
                name = (name or "?"):gsub("_", " ") }
        end
    end
    trail("loaded %d repair NPC(s) / innkeeper(s)", book_n)
end

local function save()
    dirty = false
    local out = {}
    for _, e in pairs(book) do
        out[#out + 1] = string.format("%d %d %.1f %.1f %.1f %d %d %s", e.cont, e.npc, e.x, e.y, e.z,
            e.repair and 1 or 0, e.inn and 1 or 0, (tostring(e.name or "?"):gsub("%s", "_")))
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    -- write_data_file APPENDS: empty the file first (deathzones.lua)
    pcall(function() core.create_data_file(FILE) end)
    pcall(function() core.write_data_file(FILE, table.concat(out, "\n") .. "\n") end)
end

--- Remember one NPC (exposed for the tests).
function M.remember(cont, npc, x, y, z, repair, inn, name)
    if not loaded then load() end
    if type(npc) ~= "number" or npc <= 0 or type(x) ~= "number" then return false end
    local key = cont .. "|" .. npc
    local e = book[key]
    if e and math.abs(e.x - x) < 3 and math.abs(e.y - y) < 3 and e.repair == repair and e.inn == inn then
        return false
    end
    if not e then
        if book_n >= MAX_KEEP then return false end
        book_n = book_n + 1
        trail("%s %s (npc %d) at (%.0f, %.0f)", repair and "repairer" or "innkeeper", tostring(name), npc, x, y)
    end
    book[key] = { cont = cont, npc = npc, x = x, y = y, z = z, repair = repair, inn = inn, name = name }
    dirty = true
    return true
end

--- Note every repairer / innkeeper in sight (every SCAN_EVERY s).
function M.scan(player)
    if not loaded then load() end
    local t = now()
    if dirty and t >= next_save then
        next_save = t + SAVE_GAP
        save()
    end
    if t < next_scan or not player then return end
    next_scan = t + SCAN_EVERY
    local okt, targeting = pcall(require, "targeting")
    if not okt or type(targeting) ~= "table" or type(targeting.visible_objects) ~= "function" then return end
    local list = safe(function() return targeting.visible_objects() end)
    if type(list) ~= "table" then return end
    local here = safe(function() return player:get_position() end)
    local cont = continent(here)
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true then
            local flags = safe(function() return u:get_npc_flags() end)
            local rep, inn = has_flag(flags, NPC_REPAIR), has_flag(flags, NPC_INNKEEPER)
            if rep or inn then
                local p = safe(function() return u:get_position() end)
                local npc = safe(function() return u:get_npc_id() end)
                if p and npc then
                    M.remember(cont, npc, p.x, p.y, p.z, rep, inn, safe(function() return u:get_name() end))
                end
            end
        end
    end
end

--- The nearest remembered repairer or innkeeper on the player's continent,
--- as a merchant record { npc_id, name, x, y, z, repair, inn }, and its flat
--- distance. want_repair: a repairer is taken over a nearer innkeeper.
function M.nearest(player, want_repair)
    if not loaded then load() end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local cont = continent(me)
    local best, best_d, best_rank = nil, nil, nil
    for _, e in pairs(book) do
        if e.cont == cont then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            local rank = (want_repair and not e.repair) and 2 or 1
            if d <= MAX_DIST and (best_rank == nil or rank < best_rank or (rank == best_rank and d < best_d)) then
                best, best_d, best_rank = e, d, rank
            end
        end
    end
    if not best then return nil end
    return { npc_id = best.npc, name = best.name, x = best.x, y = best.y, z = best.z,
        repair = best.repair, inn = best.inn, from_book = true }, best_d
end

function M.count()
    if not loaded then load() end
    return book_n
end

-- ============================================================================
-- ROUTE VENDOR (3.0.0): the user picks the NPC a route sells / repairs at.
-- "Save Target as Route Vendor" (Vendor tab) stores the targeted NPC for the
-- loaded / selected route: npc id, name, position, whether it repairs. A
-- grind route with a saved vendor goes there for full bags and worn gear
-- (vendor.lua path_merchant), before anything the bot finds on its own.
-- Kept in scripts_data/mfb/route_vendors.txt, one line per route id.
-- The menu button only records the click (the render pass must not touch
-- the game); M.tick carries it out on the update tick.
-- ============================================================================
local RV_FILE = FOLDER .. "/route_vendors.txt"
local NPC_VENDOR = 0x80
local rv, rv_loaded = {}, false
local pending = nil            -- "save" | "clear"

local function rv_load()
    rv_loaded = true
    local body = safe(function() return core.read_data_file(RV_FILE) end)
    if type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        local key, npc, x, y, z, rep, name = line:match("^(%S+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%d) (.*)$")
        npc, x, y, z = tonumber(npc), tonumber(x), tonumber(y), tonumber(z)
        if key and npc and x and y and z then
            rv[key] = { npc_id = npc, x = x, y = y, z = z, repair = rep == "1",
                name = (name or "?"):gsub("_", " "), route_vendor = true }
        end
    end
end

local function rv_save()
    local out = {}
    for key, e in pairs(rv) do
        out[#out + 1] = string.format("%s %d %.1f %.1f %.1f %d %s", key, e.npc_id, e.x, e.y, e.z,
            e.repair and 1 or 0, (tostring(e.name or "?"):gsub("%s", "_")))
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    pcall(function() core.create_data_file(RV_FILE) end)
    pcall(function() core.write_data_file(RV_FILE, table.concat(out, "\n") .. "\n") end)
end

--- The saved vendor of route `key` (path.id), or nil.
function M.route_vendor(key)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or key == "" then return nil end
    return rv[key]
end

--- Menu click (render pass): only recorded.
function M.request(kind)
    pending = kind
end

--- Store `unit` as the vendor of route `key`. Returns ok, message.
function M.save_route_vendor(key, unit, player)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or key == "" then return false, "load or select a route first" end
    if not unit then return false, "target the vendor NPC first" end
    if safe(function() return unit:is_player() end) == true then return false, "the target is a player" end
    local flags = safe(function() return unit:get_npc_flags() end)
    local sells, repairs = has_flag(flags, NPC_VENDOR), has_flag(flags, NPC_REPAIR)
    if not sells and not repairs then return false, "the target is not a vendor" end
    if player and safe(function() return player:can_attack(unit) end) == true then
        return false, "the target is hostile"
    end
    local p = safe(function() return unit:get_position() end)
    local npc = safe(function() return unit:get_npc_id() end)
    if not p or not npc then return false, "the target has no position / npc id" end
    local name = safe(function() return unit:get_name() end) or "?"
    rv[key] = { npc_id = npc, x = p.x, y = p.y, z = p.z, repair = repairs, name = name, route_vendor = true }
    rv_save()
    return true, string.format("%s (npc %d%s) saved as the vendor of route %s", name, npc,
        repairs and ", repairs" or "", key)
end

function M.clear_route_vendor(key)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or rv[key] == nil then return false, "no saved vendor for this route" end
    rv[key] = nil
    rv_save()
    return true, "route vendor cleared for " .. key
end

--- Update tick: carry out a menu click. `route_key` = the loaded / selected route id.
function M.tick(player, route_key)
    local kind = pending
    if not kind then return end
    pending = nil
    local ok, msg
    if kind == "save" then
        local target = player and safe(function() return player:get_target() end)
        ok, msg = M.save_route_vendor(route_key, target, player)
    else
        ok, msg = M.clear_route_vendor(route_key)
    end
    local line = "[Master Farmer - Grindbot] Route vendor: " .. tostring(msg)
    if ok then pcall(core.log, line) else pcall(core.log_warning, line) end
    trail("%s", tostring(msg))
end

--- Test hook.
function M._reset()
    book, book_n, loaded, dirty, next_scan = {}, 0, true, false, -1e9
end

return M
