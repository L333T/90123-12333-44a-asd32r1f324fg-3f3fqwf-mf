-- ============================================================================
-- Master Farmer - Grindbot
-- Debug log, written to scripts_data
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.16.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Every debug toggle in this project used core.log, which goes to the console
-- and nowhere else. A console line is gone the moment it scrolls, and there
-- is no way to send one to anybody - which is exactly what you want a debug
-- toggle for. These lines go to a file as well.
--
-- WRITE_DATA_FILE OVERWRITES, IT DOES NOT APPEND
--   So a log cannot be written a line at a time. The lines are kept in memory
--   and the whole buffer is rewritten on a debounce. That costs one string
--   concat per flush and bounds the file, which a per-line append would not.
--
-- THE BUFFER IS CAPPED
--   LIMIT lines, oldest dropped. A bot left running overnight with a debug
--   toggle on would otherwise write a file until the disk complained, and the
--   interesting part of a debug log is almost always the end of it.
--
-- PATHS ARE RELATIVE
--   core.write_data_file resolves against scripts_data itself, so the path
--   must NOT start with scripts_data/ - passing one produces
--   scripts_data/scripts_data/... and the file appears to vanish.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local debuglog = {}

local FOLDER = "mfg"
local FILE = FOLDER .. "/debug.log"
local LIMIT = 4000          -- lines kept in memory and written out
local FLUSH_GAP = 3.0       -- seconds between writes

local lines = {}
local count = 0
local dirty = false
local last_flush = -1e9
local folder_made = false
local warned = false

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

local function ensure_folder()
    if folder_made then
        return
    end
    folder_made = true
    pcall(function() core.create_data_folder(FOLDER) end)
end

-- ----------------------------------------------------------------------------
-- WRITING
-- ----------------------------------------------------------------------------

--- Add a line. Cheap: no file work happens here.
---
--- `tag` groups the line - "guide", "quest", "rest" - so one file can carry
--- every subsystem and still be readable.
function debuglog.line(tag, fmt, ...)
    local text
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        text = ok and formatted or tostring(fmt)
    else
        text = tostring(fmt)
    end

    local stamp = safe(function() return izi.now() end)
    local head = (type(stamp) == "number") and string.format("[%8.1f] ", stamp) or ""

    count = count + 1
    lines[count] = head .. tostring(tag) .. ": " .. text
    dirty = true

    -- Drop the oldest half when the cap is hit, rather than one line per write
    -- from then on: shifting a 4000-entry array on every line is the kind of
    -- thing that makes a debug toggle change the behaviour it is meant to
    -- observe.
    if count > LIMIT then
        local keep = {}
        local n = 0
        for i = math.floor(LIMIT / 2), count do
            n = n + 1
            keep[n] = lines[i]
        end
        lines = keep
        count = n
    end
end

--- Write the buffer out. Debounced unless `force` is true.
function debuglog.flush(force)
    if not dirty or count < 1 then
        return false
    end
    local now = safe(function() return izi.now() end) or 0
    if force ~= true and (now - last_flush) < FLUSH_GAP then
        return false
    end
    last_flush = now
    dirty = false

    ensure_folder()
    local body = table.concat(lines, "\n", 1, count) .. "\n"
    local ok = pcall(function()
        core.write_data_file(FILE, body)
    end)
    if not ok and not warned then
        warned = true
        core.log_warning(
            "[Master Farmer - Grindbot] Could not write " .. FILE .. " - debug lines stay in the console only.")
    end
    return ok
end

--- Called once per frame from main.lua. Writing is debounced inside flush.
function debuglog.tick()
    debuglog.flush(false)
end

--- Start a fresh file. Called when the bot starts, so one run is one log.
function debuglog.reset(note)
    lines = {}
    count = 0
    dirty = true
    if note then
        debuglog.line("log", tostring(note))
    end
    debuglog.flush(true)
end

--- Where the file lands, for a status line or a log message.
function debuglog.path()
    return "scripts_data/" .. FILE
end

--- How many lines are buffered.
function debuglog.count()
    return count
end

return debuglog
