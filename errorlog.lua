-- ============================================================================
-- Master Farmer - Grindbot
-- Error log, written to scripts_log/MASTER_FARMER_ERRORS
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.21.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- One file per session:
--
--     scripts_log/MASTER_FARMER_ERRORS/session_2026-09-26_14-03-55.log
--
-- Three kinds of line go in it:
--
--   ERROR   a Lua error caught by errorlog.guard, with the traceback and a
--           snapshot of what the bot was doing (mode, status line, position,
--           map, current quest goal). The same error is written once, then
--           counted, so an error thrown every frame cannot fill the disk.
--   WARN    something recoverable that is still worth knowing about.
--   TRAIL   a breadcrumb: quest start, a new goal, a new walk destination, a
--           waypoint conversion. Written only when it differs from the last
--           one with the same tag, so a steady state costs nothing.
--
-- WHY EVERY LINE IS WRITTEN IMMEDIATELY
--   A game crash is not a Lua error: the process dies and no buffer is ever
--   flushed. The only record that survives is what already reached the disk,
--   so each line is appended as it happens. The last TRAIL lines in the file
--   of a crashed session say what the bot was doing when the game went down.
--   core.write_log_file appends (FB_Nexus logs line by line through it).
--
-- NOTHING HERE MAY THROW
--   This runs inside the error path. Every native call is wrapped, and a
--   failure to write turns logging off for the session rather than raising a
--   second error on top of the first.
-- ============================================================================

local errorlog = {}

local unpack = table.unpack or unpack

local FOLDER = "MASTER_FARMER_ERRORS"
local MAX_LINES = 20000       -- per session; beyond this only ERRORs are written
local REPEAT_NOTE = 50        -- re-log a repeating error every N occurrences

local path = nil              -- this session's file, relative to scripts_log
local opened = false
local disabled = false
local lines = 0
local seen = {}               -- error key -> count
local last_trail = {}         -- tag -> last text
local context_fn = nil

local function stamp()
    local ok, t = pcall(function() return core.get_local_time() end)
    if ok and type(t) == "table" then
        return string.format("%04d-%02d-%02d %02d:%02d:%02d",
            tonumber(t.year) or 0, tonumber(t.month) or 0, tonumber(t.day) or 0,
            tonumber(t.hour) or 0, tonumber(t.minute) or 0, tonumber(t.second) or 0)
    end
    return "????-??-?? ??:??:??"
end

--- Seconds since the game started. core.time() already reports seconds; the
--- 2.20.0 log divided it by 1000 and every line read "t=0.69".
local function game_time()
    local ok, t = pcall(function() return core.time() end)
    if ok and type(t) == "number" then
        return string.format("%.2f", t)
    end
    return "-"
end

local function open()
    if opened then
        return path ~= nil
    end
    opened = true
    if type(core) ~= "table" or type(core.write_log_file) ~= "function" then
        disabled = true
        return false
    end
    pcall(function() core.create_log_folder(FOLDER) end)
    local name = stamp():gsub("[: ]", function(c) return c == " " and "_" or "-" end)
    path = FOLDER .. "/session_" .. name .. ".log"
    pcall(function() core.create_log_file(path) end)
    return true
end

local function write(kind, text)
    if disabled or not open() then
        return
    end
    if lines >= MAX_LINES and kind ~= "ERROR" then
        return
    end
    lines = lines + 1
    local line = string.format("%s  t=%s  %-5s %s\n", stamp(), game_time(), kind, text)
    local ok = pcall(core.write_log_file, path, line)
    if not ok then
        disabled = true
    end
end

--- Plain value to text, one level deep, for the context snapshot.
local function show(v)
    if type(v) ~= "table" then
        return tostring(v)
    end
    local parts = {}
    for k, x in pairs(v) do
        if type(x) ~= "table" and type(x) ~= "function" then
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(x)
        end
    end
    table.sort(parts)
    return "{" .. table.concat(parts, " ") .. "}"
end

local function context_lines()
    if type(context_fn) ~= "function" then
        return
    end
    local ok, ctx = pcall(context_fn)
    if not ok then
        write("ERROR", "    context: (failed: " .. tostring(ctx) .. ")")
        return
    end
    if type(ctx) ~= "table" then
        return
    end
    local keys = {}
    for k in pairs(ctx) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    for i = 1, #keys do
        write("ERROR", string.format("    %-10s %s", keys[i], show(ctx[keys[i]])))
    end
end

local function traceback(err)
    local dbg = rawget(_G, "debug")
    if type(dbg) == "table" and type(dbg.traceback) == "function" then
        local ok, tb = pcall(dbg.traceback, tostring(err), 2)
        if ok and type(tb) == "string" then
            return tb
        end
    end
    return tostring(err)
end

-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------

--- Start the session file and write its header.
function errorlog.start(version)
    if not open() then
        return
    end
    write("INFO", "==================================================================")
    write("INFO", "Master Farmer - Grindbot v" .. tostring(version) .. " session start")
    write("INFO", "==================================================================")
end

--- A function returning a table of what the bot is doing, for error snapshots.
function errorlog.set_context(fn)
    context_fn = fn
end

--- Record a Lua error. `where` names the call that threw.
function errorlog.error(where, err, tb)
    local key = tostring(where) .. "|" .. tostring(err)
    local n = (seen[key] or 0) + 1
    seen[key] = n
    if n > 1 and n % REPEAT_NOTE ~= 0 then
        return
    end
    if n > 1 then
        write("ERROR", string.format("%s: repeated %d times: %s", tostring(where), n, tostring(err)))
        return
    end
    write("ERROR", tostring(where) .. ": " .. tostring(err))
    for l in tostring(tb or err):gmatch("[^\n]+") do
        write("ERROR", "    " .. l)
    end
    context_lines()
    pcall(function()
        core.log_error("[Master Farmer - Grindbot] " .. tostring(where) .. ": " .. tostring(err)
            .. "  (details: scripts_log/" .. tostring(path) .. ")")
    end)
end

function errorlog.warn(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    write("WARN", ok and text or tostring(fmt))
end

function errorlog.info(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    write("INFO", ok and text or tostring(fmt))
end

--- A breadcrumb. Written only when it differs from the previous one with the
--- same tag, so calling this every frame with an unchanged value is free.
function errorlog.trail(tag, fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    text = ok and text or tostring(fmt)
    if last_trail[tag] == text then
        return
    end
    last_trail[tag] = text
    write("TRAIL", tostring(tag) .. ": " .. text)
end

--- Run fn(...) and record anything it throws. Returns ok, first result.
function errorlog.guard(where, fn, ...)
    local args = { n = select("#", ...), ... }
    local tb = nil
    local ok, res = xpcall(function()
        return fn(unpack(args, 1, args.n))
    end, function(e)
        tb = traceback(e)
        return e
    end)
    if not ok then
        errorlog.error(where, res, tb)
    end
    return ok, res
end

-- ----------------------------------------------------------------------------
-- MEMORY
-- ----------------------------------------------------------------------------
-- A MEM line every MEM_GAP seconds: the Lua heap now, and the peak since the
-- session began. A heap that climbs from line to line is a leak; one that
-- saws up and down is churn the collector is keeping up with.
local MEM_GAP = 30
local mem_next = 0
local mem_peak = 0

local function heap_kb()
    local ok, kb = pcall(collectgarbage, "count")
    if ok and type(kb) == "number" then
        return kb
    end
    return nil
end

--- Called every frame from main.lua. Cheap when it is not time to write.
function errorlog.tick(now)
    local kb = heap_kb()
    if kb and kb > mem_peak then
        mem_peak = kb
    end
    if type(now) ~= "number" or now < mem_next then
        return
    end
    mem_next = now + MEM_GAP
    if kb then
        write("MEM", string.format("lua heap %.0f KB  (peak %.0f KB)", kb, mem_peak))
    end
end

--- Where this session's file is, for a status line.
function errorlog.path()
    return path and ("scripts_log/" .. path) or nil
end

return errorlog
