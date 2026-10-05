-- ============================================================================
-- AmeisenNav
-- anav/log.lua - console, session log file and server log
-- ============================================================================
-- Version: 1.0.0
-- Author: BLIZZ
-- ============================================================================
-- Every line goes to (debug lines reach the console only with "Debug log"):
--
--   console   core.log / log_warning / log_error
--   file      one file per session, newest C.log_keep kept:
--               scripts_log/ameisen_nav/nav_<stamp>.log        (appended), or
--               scripts_data/ameisen_nav/logs/nav_<stamp>.log  when scripts_log
--               is not writable (kept in memory, rewritten every 2 s)
--   server    POST <base_url>/log?src=ameisen_nav every 2 s. The HTTP bridge
--             accepts the POST so boot/status lines are not treated as errors.
--
-- Every file call is checked and the result is logged ("file log: ..."), so a
-- loader that refuses writes says so instead of failing silently.
-- ============================================================================

local C = require("anav/config")

local TAG = "[AmeisenNav]"
local LOG_DIR = "ameisen_nav"
local SERVER_SRC = "ameisen_nav"

local L = {}

-- Recent lines for the menu's "Recent log" view (ring buffer).
local RING = 40
L.recent = {}
local head = 0

local function remember(s)
    head = head % RING + 1
    L.recent[head] = s
end

--- Recent lines, oldest first.
function L.lines()
    local out = {}
    for i = 1, RING do
        local s = L.recent[(head + i - 1) % RING + 1]
        if s then out[#out + 1] = s end
    end
    return out
end

local function fmt(f, ...)
    if select("#", ...) == 0 then return tostring(f) end
    local ok, s = pcall(string.format, f, ...)
    return ok and s or tostring(f)
end

local function now()
    local ok, t = pcall(core.time)
    return ok and type(t) == "number" and t or 0
end

-- ----------------------------------------------------------------------------
-- session file
-- ----------------------------------------------------------------------------
local MAX_BUFFER = 3000
local FLUSH_EVERY = 2.0

local backend = nil       -- nil (not opened), "log", "data" or "off"
local file_name = nil     -- relative to the backend root
local buffer, buffer_n, dirty, next_flush = {}, 0, false, 0
L.file_status = "not opened"
local pending_notes = {}  -- diagnostics collected while opening, logged afterwards

local function note(s) pending_notes[#pending_notes + 1] = s end

local function session_stamp()
    -- The Sylvanas sandbox has no `os` global: look it up without indexing nil.
    local os_lib = rawget(_G, "os")
    if type(os_lib) == "table" and type(os_lib.date) == "function" then
        local ok, s = pcall(os_lib.date, "%Y%m%d_%H%M%S")
        if ok and type(s) == "string" then return s end
    end
    -- No wall clock: one file, replaced every session (game timers restart
    -- per session, so they would not sort). The server log keeps history.
    return "latest"
end

local function list_has(entries, name)
    if type(entries) ~= "table" then return false end
    for i = 1, #entries do
        if entries[i] == name then return true end
    end
    return false
end

--- pcall a core function by name; returns ok, result, and a short description.
local function try(name, ...)
    local fn = core[name]
    if type(fn) ~= "function" then return false, nil, name .. " missing" end
    local ok, r = pcall(fn, ...)
    if not ok then return false, nil, name .. " error: " .. tostring(r) end
    return true, r, name .. " -> " .. tostring(r)
end

--- Delete the oldest session files beyond C.log_keep.
local function rotate(list_name, delete_name, dir)
    local ok, entries = try(list_name, dir)
    if not ok or type(entries) ~= "table" then return end
    local logs = {}
    for i = 1, #entries do
        if type(entries[i]) == "string" and entries[i]:match("^nav_.*%.log$") then logs[#logs + 1] = entries[i] end
    end
    if #logs <= C.log_keep then return end
    table.sort(logs)
    for i = 1, #logs - C.log_keep do try(delete_name, dir .. "/" .. logs[i]) end
end

--- scripts_log backend: create the file, then confirm it really exists.
local function open_log_backend(base)
    local name = LOG_DIR .. "/" .. base
    local ok, made, d = try("create_log_folder", LOG_DIR)
    if not ok or made == false then return false, d end
    ok, _, d = try("create_log_file", name)
    if not ok then return false, d end
    ok, _, d = try("write_log_file", name, "")
    if not ok then return false, d end
    local okl, entries, dl = try("read_log_dir", LOG_DIR)
    if not okl then return false, dl end
    if not list_has(entries, base) then
        return false, "file not listed after create (read_log_dir gave " .. tostring(type(entries) == "table" and #entries or entries) .. " entries)"
    end
    rotate("read_log_dir", "delete_log_file", LOG_DIR)
    file_name = name
    return true
end

--- scripts_data backend: create, write a header, confirm the size.
local function open_data_backend(base)
    local dir = LOG_DIR .. "/logs"
    try("create_data_folder", LOG_DIR)
    try("create_data_folder", dir)
    local name = dir .. "/" .. base
    -- without a wall clock every session reuses this name, and a write appends,
    -- so drop the previous session's file rather than growing it forever
    try("delete_data_file", name)
    local ok, _, d = try("create_data_file", name)
    if not ok then return false, d end
    local probe = "AmeisenNav session log\n"
    ok, _, d = try("write_data_file", name, probe)
    if not ok then return false, d end
    local oks, size, ds = try("get_data_file_size", name)
    if oks and type(size) == "number" and size <= 0 then
        return false, "write_data_file left the file empty (" .. ds .. ")"
    end
    rotate("read_dir", "delete_data_file", dir)
    file_name = name
    -- the probe is already in the file; the buffer only holds unsent lines
    buffer, buffer_n = {}, 0
    return true
end

local function open_file()
    if backend then return backend ~= "off" end
    if not C.file_log then
        backend, L.file_status = "off", "disabled (file_log = false)"
        return false
    end
    local base = "nav_" .. session_stamp() .. ".log"
    local ok, why = open_log_backend(base)
    if ok then
        backend, L.file_status = "log", "scripts_log/" .. file_name
        return true
    end
    note("file log: scripts_log refused - " .. tostring(why))
    ok, why = open_data_backend(base)
    if ok then
        backend, L.file_status = "data", "scripts_data/" .. file_name
        return true
    end
    note("file log: scripts_data refused - " .. tostring(why))
    backend, L.file_status = "off", "no writable folder (see console)"
    return false
end

-- core.write_data_file appends on this loader, so a flush sends only the lines
-- it has not sent yet. Re-sending the whole buffer duplicated the file and grew
-- it quadratically.
local function flush_data(force)
    if backend ~= "data" or not dirty then return end
    local t = now()
    if not force and t < next_flush then return end
    next_flush = t + FLUSH_EVERY
    dirty = false
    local chunk = table.concat(buffer, "", 1, buffer_n)
    buffer, buffer_n = {}, 0
    local ok, _, d = try("write_data_file", file_name, chunk)
    if not ok then
        backend, L.file_status = "off", "write failed: " .. d
        note("file log: stopped - " .. d)
    end
end

local function to_file(level, line)
    if not open_file() then return end
    if backend == "log" then
        local ok, _, d = try("write_log_file", file_name, line)
        if not ok then
            backend, L.file_status = "off", "write failed: " .. d
            note("file log: stopped - " .. d)
        end
        return
    end
    buffer_n = buffer_n + 1
    buffer[buffer_n] = line
    if buffer_n > MAX_BUFFER then
        local keep = {}
        for i = buffer_n - MAX_BUFFER + 1, buffer_n do keep[#keep + 1] = buffer[i] end
        buffer, buffer_n = keep, #keep
    end
    dirty = true
    flush_data(level == "WARN" or level == "ERROR")
end

--- Where the session log file is, or nil.
function L.file()
    if backend == "log" or backend == "data" then return L.file_status end
    return nil
end

-- ----------------------------------------------------------------------------
-- server log (POST /log)
-- ----------------------------------------------------------------------------
local srv_lines, srv_n, srv_next, srv_inflight = {}, 0, 0, false
local srv_off = false     -- the server has no /log endpoint (old build): stop for this session
local SRV_MAX = 2000
local SRV_RETRY = 10.0    -- seconds between attempts while the server is unreachable
L.server_status = "waiting"

local function to_server(line)
    if not C.server_log or srv_off then return end
    srv_n = srv_n + 1
    srv_lines[srv_n] = line
    if srv_n > SRV_MAX then
        local keep = {}
        for i = srv_n - SRV_MAX + 1, srv_n do keep[#keep + 1] = srv_lines[i] end
        srv_lines, srv_n = keep, #keep
    end
end

local function flush_server(force)
    if srv_n == 0 or srv_inflight or not C.server_log or srv_off then return end
    local t = now()
    if not force and t < srv_next then return end
    srv_next = t + FLUSH_EVERY
    local body = table.concat(srv_lines, "", 1, srv_n)
    local sent_n = srv_n
    srv_inflight = true
    local url = C.base_url .. "/log?src=" .. SERVER_SRC
    local function handle(code)
        if code == 200 then
            -- drop what was sent; keep anything logged meanwhile
            local rest = {}
            for i = sent_n + 1, srv_n do rest[#rest + 1] = srv_lines[i] end
            srv_lines, srv_n = rest, #rest
            L.server_status = "Ameisen\\http_bridge /log"
        elseif code == 404 or code == 405 then
            -- an older nav server without /log: nothing will ever accept these
            srv_off = true
            srv_lines, srv_n = {}, 0
            L.server_status = "off: this nav server has no /log - update it"
        else
            -- unreachable or busy: keep the (capped) buffer and try again later
            srv_next = now() + SRV_RETRY
            L.server_status = "waiting for the server (HTTP " .. tostring(code) .. ")"
        end
    end

    -- The game's HTTP layer calls this. Nothing in it may raise, and it cannot
    -- log its own failure: that would queue another line and recurse.
    local function done(code)
        srv_inflight = false
        if not pcall(handle, code) then
            srv_next = now() + SRV_RETRY
            L.server_status = "the last log upload could not be handled"
        end
    end
    local ok
    if C.token and C.token ~= "" then
        ok = pcall(core.http_post, url, { ["X-Nav-Token"] = C.token }, body, done)
    else
        ok = pcall(core.http_post, url, body, done)
    end
    if not ok then srv_inflight = false end
end

-- ----------------------------------------------------------------------------
-- output
-- ----------------------------------------------------------------------------

-- The console rejects long strings ("core.log_error received string of size ?"),
-- so it gets the first line, capped. Files and the server log keep everything.
local CONSOLE_MAX = 200

local function console_text(s)
    local first = s:match("^[^\n]*") or s
    if #first > CONSOLE_MAX then first = first:sub(1, CONSOLE_MAX - 3) .. "..." end
    if first ~= s then first = first .. " (full text in the log file)" end
    return TAG .. " " .. first
end

local function console(fn, s)
    pcall(fn, console_text(s))
end

local writing = false

local function emit(level, s)
    local line = string.format("%9.2f %-5s %s\n", now(), level, s)
    to_server(line)
    if writing then return end -- a note raised while opening the file
    writing = true
    if C.file_log then to_file(level, line) end
    writing = false
    -- report what the file backends said, once, on every channel
    if #pending_notes > 0 then
        local notes = pending_notes
        pending_notes = {}
        for i = 1, #notes do
            remember("WARN " .. notes[i])
            to_server(string.format("%9.2f %-5s %s\n", now(), "WARN", notes[i]))
            console(core.log_warning, notes[i])
        end
    end
end

--- Turn any error value into text. The loader's menu library throws tables,
--- which tostring() shows only as "table: 0x...".
function L.describe(err)
    if type(err) ~= "table" then return tostring(err) end
    local parts = {}
    for k, v in pairs(err) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        if #parts >= 12 then break end
    end
    local mt = getmetatable(err)
    local ok, s = pcall(tostring, err)
    if mt and mt.__tostring and ok then parts[#parts + 1] = "tostring=" .. s end
    return "{" .. table.concat(parts, ", ") .. "}"
end

--- xpcall error handler: readable message plus a traceback.
function L.traceback(err)
    local msg = L.describe(err)
    local dbg = rawget(_G, "debug")
    if type(dbg) == "table" and type(dbg.traceback) == "function" then
        local ok, tb = pcall(dbg.traceback, "", 2)
        if ok and tb then msg = msg .. "\n" .. tb end
    end
    return msg
end

--- Call every frame: writes buffered file / server output when due.
function L.flush(force)
    flush_data(force)
    flush_server(force)
end

function L.info(f, ...)
    local s = fmt(f, ...)
    remember(s)
    emit("INFO", s)
    console(core.log, s)
end

function L.warn(f, ...)
    local s = fmt(f, ...)
    remember("WARN " .. s)
    emit("WARN", s)
    console(core.log_warning, s)
end

function L.error(f, ...)
    local s = fmt(f, ...)
    remember("ERR  " .. s)
    emit("ERROR", s)
    console(core.log_error, s)
end

--- Always written to the file, server log and ring; console only with "Debug log".
function L.debug(f, ...)
    local s = fmt(f, ...)
    remember(s)
    emit("DEBUG", s)
    if C.debug_log then console(core.log, s) end
end

return L
