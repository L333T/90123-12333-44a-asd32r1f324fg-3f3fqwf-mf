-- ============================================================================
-- AmeisenNav
-- anav/context.lua - who / where the player is, in the server's terms
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- map id     the world map id the mmaps use (0 = Eastern Kingdoms,
--            1 = Kalimdor), from core.get_instance_id(). core.get_map_id()
--            is the UI map on WoW Forever (1429 = Elwynn Forest).
-- state      the server's query filter: normal | alliance | horde | dead.
--            Faction states make paths avoid the other faction's towns;
--            dead lets a ghost cross water it would otherwise route around.
-- ============================================================================

local X = {}

-- ----------------------------------------------------------------------------
-- crash breadcrumbs + crash guard
-- ----------------------------------------------------------------------------
-- Some native calls crash WoW Forever outright (no Lua error to catch):
-- core.graphics.trace_line did on 2026-09-28. Two defences:
--
-- BREADCRUMB  The first call of every function is written to the session log
--             BEFORE it is made (scripts_log is appended line by line), so the
--             last "calling ..." line of a crashed session names the culprit.
--
-- GUARD       Around the same first call, its name is appended to
--             scripts_data/ameisen_nav/guard/pending.txt, and DONE is appended
--             when the call returns. At load, a last line that is not DONE means
--             that call took the game down last session: it is added to
--             guard/blocked.txt and never called again (X.call / X.call_fn
--             return false, "blocked"). Delete blocked.txt to allow a call again.
--             The guard only sees first calls, so a crash in a call the plugin
--             has already made once leaves the journal closed on DONE.
local L = require("anav/log")
local called = {}

local GUARD_DIR = "ameisen_nav/guard"
local PENDING = GUARD_DIR .. "/pending.txt"
local BLOCKED_FILE = GUARD_DIR .. "/blocked.txt"

-- Known to crash WoW Forever: blocked from the start, whatever the files say.
local ALWAYS_BLOCKED = { ["core.graphics.trace_line"] = true }

-- core.write_data_file APPENDS on this loader. The File I/O docs only promise
-- "in most systems, this overwrites", and this one does not, so the guard file
-- is a journal rather than a slot: one line per entry, and the last line is the
-- state. DONE closes an entry. Reading the last line is correct either way, so
-- this keeps working on a loader that does overwrite.
--
-- Writing "" (1.4.0) appended nothing and left the old name in place, which is
-- how core.get_instance_id got accused of a crash it had already returned from.
local DONE = "-"

local blocked = {}
for k in pairs(ALWAYS_BLOCKED) do blocked[k] = true end
local guard_ok = false

local function data(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

--- Replace a data file's contents. A plain write appends, so delete it first.
local function rewrite(path, text)
    data(core.delete_data_file, path)
    data(core.create_data_file, path)
    return (data(core.write_data_file, path, text))
end

--- The newest journal entry: the last non-empty line.
local function last_entry(text)
    local last = nil
    for line in text:gmatch("[^\r\n]+") do
        local s = line:match("^%s*(.-)%s*$")
        if s ~= "" then last = s end
    end
    return last
end

local function load_guard()
    data(core.create_data_folder, "ameisen_nav")
    data(core.create_data_folder, GUARD_DIR)

    local okb, text = data(core.read_data_file, BLOCKED_FILE)
    if okb and type(text) == "string" then
        for line in text:gmatch("[^\r\n]+") do
            local name = line:match("^%s*(.-)%s*$")
            if name ~= "" and name ~= DONE then blocked[name] = true end
        end
    end

    local okp, journal = data(core.read_data_file, PENDING)
    local culprit = okp and type(journal) == "string" and last_entry(journal) or nil
    if culprit and culprit ~= DONE then
        blocked[culprit] = true
        L.warn("crash guard: '%s' was running when the game went down last session - it is blocked from now on", culprit)
        local list = {}
        for k in pairs(blocked) do
            if not ALWAYS_BLOCKED[k] then list[#list + 1] = k end
        end
        table.sort(list)
        rewrite(BLOCKED_FILE, table.concat(list, "\n") .. "\n")
    end

    guard_ok = rewrite(PENDING, DONE .. "\n")
end
load_guard()

local function first_call(label)
    called[label] = true
    L.debug("calling %s for the first time", label)
    if guard_ok then data(core.write_data_file, PENDING, label .. "\n") end
end

local function first_done()
    if guard_ok then data(core.write_data_file, PENDING, DONE .. "\n") end
end

local unpack_ = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

--- True when `label` has been blocked by the crash guard.
function X.is_blocked(label) return blocked[label] == true end

--- pcall(obj[name], obj, ...) with a breadcrumb and crash guard on first use of `name`.
function X.call(obj, name, ...)
    if obj == nil then return false, "nil object" end
    local label = ":" .. name .. "()"
    if blocked[label] then return false, "blocked" end
    local fn = obj[name]
    if type(fn) ~= "function" then return false, name .. " missing" end
    if called[label] then return pcall(fn, obj, ...) end
    first_call(label)
    local r = pack(pcall(fn, obj, ...))
    first_done()
    return unpack_(r, 1, r.n)
end

--- pcall(core-style function) with a breadcrumb and crash guard on first use of `label`.
function X.call_fn(label, fn, ...)
    if blocked[label] then return false, "blocked" end
    if type(fn) ~= "function" then return false, label .. " missing" end
    if called[label] then return pcall(fn, ...) end
    first_call(label)
    local r = pack(pcall(fn, ...))
    first_done()
    return unpack_(r, 1, r.n)
end

--- header.lua no longer gates on version; keep this table for older callers.
X.SUPPORTED = { Forever = true, Tbc = true, Vanilla = true, Midnight = true, Mop = true, Titan = true }

--- core.get_game_version(), or nil.
function X.game_version()
    local ok, v = pcall(core.get_game_version)
    return ok and v or nil
end

--- core.get_exact_game_version(), or nil. "wow_forever_beta_us" on Forever,
--- "wow_tbc_us" / "wow_tbc_cn" / "wow_tbc_ps" on the TBC clients.
function X.exact_version()
    local ok, v = pcall(core.get_exact_game_version)
    return ok and v or nil
end

--- The version of the client this is running on, read once at load.
X.GAME_VERSION = X.game_version()

--- The exact build, read once at load (informational).
X.EXACT_VERSION = X.exact_version()

--- True on the WoW Forever client, which needs the fallbacks in this file.
function X.is_forever()
    return X.GAME_VERSION == "Forever"
end

--- True on either TBC client (Blizzard 2.5.3 or the private-server build).
function X.is_tbc()
    return X.GAME_VERSION == "Tbc"
end

--- True when this client is one the plugin supports.
function X.is_supported()
    return true
end

-- Classic race ids -> faction filter.
local RACE_STATE = {
    [1] = "alliance", [3] = "alliance", [4] = "alliance", [7] = "alliance", [11] = "alliance",
    [2] = "horde",    [5] = "horde",    [6] = "horde",    [8] = "horde",    [10] = "horde",
}


--- Instance ids that differ from the mesh file ids (none known yet).
X.MAP_REMAP = {}

-- ----------------------------------------------------------------------------
-- local player
-- ----------------------------------------------------------------------------
-- On WoW Forever core.object_manager.get_local_player() has returned nil while
-- the character is in the world, so three sources are tried in order and the
-- one that worked is reported by X.player_status():
--   1. core.object_manager.get_local_player()
--   2. core.object_manager.get_object_from_guid("player")   (unit token)
--   3. the object whose get_guid() equals UnitGUID("player"), found by
--      scanning the object manager (at most every SCAN_GAP seconds)
local SCAN_GAP = 2.0
local player_source = "none"
local scanned_obj, next_scan = nil, 0
local cached_player_guid = nil

local function usable(obj)
    if obj == nil then return false end
    local ok, valid = X.call(obj, "is_valid")
    return not (ok and valid == false)
end

local function player_guid()
    if cached_player_guid then return cached_player_guid end
    local unit_guid = rawget(_G, "UnitGUID")
    if type(unit_guid) ~= "function" then return nil end
    local ok, g = pcall(unit_guid, "player")
    if ok and type(g) == "string" and g ~= "" then cached_player_guid = g end
    return cached_player_guid
end

local function scan_for_player()
    local guid = player_guid()
    if not guid then return nil end
    for _, list_fn in ipairs({ core.object_manager.get_visible_objects, core.object_manager.get_all_objects }) do
        local ok, list = pcall(list_fn)
        if ok and type(list) == "table" then
            for _, obj in pairs(list) do
                local okg, g = X.call(obj, "get_guid")
                if okg and g == guid then return obj end
            end
        end
    end
    return nil
end

local frame_t, frame_player = nil, nil

function X.player()
    local t = core.time()
    if t == frame_t then return frame_player end
    frame_t = t
    frame_player = X.find_player()
    return frame_player
end

function X.find_player()
    local okp, p = X.call_fn("get_local_player", core.object_manager.get_local_player)
    if okp and usable(p) then
        player_source = "get_local_player"
        return p
    end
    local okt, t = X.call_fn("get_object_from_guid(player)", core.object_manager.get_object_from_guid, "player")
    if okt and usable(t) then
        player_source = "get_object_from_guid('player')"
        return t
    end
    if usable(scanned_obj) then
        player_source = "object scan (UnitGUID)"
        return scanned_obj
    end
    local now = core.time()
    if now >= next_scan then
        next_scan = now + SCAN_GAP
        scanned_obj = scan_for_player()
        if usable(scanned_obj) then
            player_source = "object scan (UnitGUID)"
            return scanned_obj
        end
    end
    player_source = "none"
    return nil
end

--- The player's current target object, or nil.
function X.target()
    local p = X.player()
    if p then
        local ok, t = X.call(p, "get_target")
        if ok and usable(t) then return t end
    end
    local ok, t = X.call_fn("get_object_from_guid(target)", core.object_manager.get_object_from_guid, "target")
    if ok and usable(t) then return t end
    return nil
end

--- Which source found the player, plus what each call returns, for diagnostics.
function X.player_status()
    local p = X.player()
    local okl, lp = X.call_fn("get_local_player", core.object_manager.get_local_player)
    local okt, tp = X.call_fn("get_object_from_guid(player)", core.object_manager.get_object_from_guid, "player")
    local parts = {
        "player via " .. player_source,
        "get_local_player=" .. (okl and (lp == nil and "nil" or type(lp)) or "error"),
        "from_guid('player')=" .. (okt and (tp == nil and "nil" or type(tp)) or "error"),
        "UnitGUID=" .. tostring(player_guid()),
    }
    if p then
        local okr, race = X.call(p, "get_race_id")
        local okf, fac = X.call(p, "get_faction_id")
        parts[#parts + 1] = "race_id=" .. (okr and tostring(race) or "?")
        parts[#parts + 1] = "faction_id=" .. (okf and tostring(fac) or "?")
    end
    return table.concat(parts, ", ")
end

--- A number from a core function, through the breadcrumb and crash guard.
local function num(label, fn)
    local ok, v = X.call_fn(label, fn)
    if ok and type(v) == "number" then return v end
    return nil
end

--- The mesh map id: 0 Eastern Kingdoms, 1 Kalimdor, 36 Deadmines ...
--- On WoW Forever core.get_map_id() returns the UI map (1429 = Elwynn Forest),
--- so the instance id is used; it is the world map id the mmaps are named by.
function X.map_id()
    local id = num("core.get_instance_id", core.get_instance_id)
    if id == nil or id < 0 then id = num("core.get_map_id", core.get_map_id) end
    if id == nil then return nil end
    return X.MAP_REMAP[id] or id
end

--- Raw ids for diagnostics: instance id, UI map id, map name, instance name.
function X.map_info()
    local okn, name = X.call_fn("core.get_map_name", core.get_map_name)
    local oki, iname = X.call_fn("core.get_instance_name", core.get_instance_name)
    return num("core.get_instance_id", core.get_instance_id),
        num("core.get_map_id", core.get_map_id),
        okn and tostring(name) or "?", oki and tostring(iname) or "?"
end

--- x, y, z of the player or nil.
function X.position()
    local p = X.player()
    if not p then return nil end
    local ok, pos = X.call(p, "get_position")
    if not ok or not pos then return nil end
    return pos.x, pos.y, pos.z
end

local cached_faction = nil
local faction_warned = false

--- "normal" | "alliance" | "horde" | "dead"
function X.filter_state()
    local p = X.player()
    if not p then return "normal" end
    local okg, ghost = X.call(p, "is_ghost")
    local okd, dead = X.call(p, "is_dead")
    if (okg and ghost) or (okd and dead) then return "dead" end
    -- menu choice wins: on WoW Forever the player object reports race 0 / faction 0
    local C = require("anav/config")
    if C.faction == "alliance" or C.faction == "horde" then return C.faction end
    if C.faction == "none" then return "normal" end
    if not cached_faction then
        -- Auto reads the race only. On WoW Forever the player object answers
        -- race_id 0, so auto cannot tell there: set Faction in the menu.
        local okr, race = X.call(p, "get_race_id")
        local okf, fac = X.call(p, "get_faction_id") -- logged for diagnostics only
        local state = okr and RACE_STATE[race] or nil
        if state then
            cached_faction = state
        elseif not faction_warned then
            faction_warned = true
            L.info("faction: auto could not tell (race_id=%s, faction_id=%s) - set Faction in the menu",
                tostring(race), tostring(fac))
        end
    end
    return cached_faction or "normal"
end

function X.is_casting()
    local p = X.player()
    if not p then return false end
    local ok1, c = X.call(p, "is_casting_spell")
    local ok2, ch = X.call(p, "is_channelling_spell")
    return (ok1 and c == true) or (ok2 and ch == true)
end

return X
