-- ============================================================================
-- Master Farmer - Grindbot
-- Error log, written to scripts_log/MASTER_FARMER_ERRORS
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.161.0
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
-- Lines per FILE (2.65.0). At the cap the session rolls over into
-- "<session>_part2.log", "_part3" ... instead of going quiet: the 20000-line
-- cap used to stop the log after about half an hour of heartbeats, so a
-- crash later in a long session left no trail at all.
local MAX_LINES = 20000
local REPEAT_NOTE = 50        -- re-log a repeating error every N occurrences

local path = nil              -- this session's file, relative to scripts_log
local base_path = nil         -- the first file's name without ".log"
local part = 1
local opened = false
local disabled = false
local lines = 0
local seen = {}               -- error key -> count
local last_trail = {}         -- tag -> last text
local context_fn = nil
-- Heartbeat state (see HEARTBEAT below). Declared up here because
-- errorlog.probe reads it and is defined first: declared below, these were
-- globals inside probe - always nil - and no BEAT ever listed a stage.
local beat_on = false
local BEAT_SAME = 2.0         -- seconds an unchanged BEAT line is held back
local beat_last_body = nil
local beat_last_t = 0
local beat_same = 0
local beat_tags = {}
local beat_n = 0

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
    base_path = FOLDER .. "/session_" .. name
    path = base_path .. ".log"
    pcall(function() core.create_log_file(path) end)
    return true
end

--- Continue the session in the next part file.
local function roll_over()
    part = part + 1
    local next_path = base_path .. "_part" .. part .. ".log"
    local ok = pcall(function() core.create_log_file(next_path) end)
    if not ok then
        return false
    end
    pcall(core.write_log_file, path, string.format("%s  (continued in %s)\n", stamp(), next_path))
    path = next_path
    lines = 0
    return true
end

local function write(kind, text)
    if disabled or not open() then
        return
    end
    if lines >= MAX_LINES and not roll_over() and kind ~= "ERROR" then
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
-- FLIGHT RECORDER
-- ----------------------------------------------------------------------------
-- TRAIL lines only record changes, and a game crash happens INSIDE a native
-- call - between two TRAIL lines that look perfectly ordinary. So for a short
-- burst after something risky starts (questing begins, a mob is engaged),
-- every probe point writes a PROBE line straight to disk, unfiltered. The
-- last PROBE line in a crashed session names the call the game died in.
--
-- Bounded by a line budget rather than time, so a burst costs a fixed amount
-- of disk however fast frames run, and re-arming only tops the budget up.
-- TIME-BASED (2.27.0). A 2,500-line burst lasted ten seconds at the frame
-- rate the recorder itself costs, and the 20:25 crash came about fifteen
-- seconds after it ran out. The recorder now runs for PROBE_WINDOW seconds
-- from the last arm, bounded only by the session's MAX_LINES.
local PROBE_WINDOW = 90
local probe_until = -1
local probe_on = false

local function now_s()
    local ok, t = pcall(function() return core.time() end)
    if ok and type(t) == "number" then
        return t
    end
    return 0
end

-- ----------------------------------------------------------------------------
-- LIGHT CAPTURE (2.87.0)
-- ----------------------------------------------------------------------------
-- Every game shutdown traced on 2026-09-27 came 0.6-1 s after the bot began
-- closing on a target (a new engage / pull, or a rest ending) - and the full
-- recorder, being opt-in and heavy, was never on. The light capture is armed
-- for a short window at exactly those moments. It writes every bot-decision
-- probe, but not the per-frame window drawing, and each per-frame movement
-- probe at most every LIGHT_FRAME_GAP s - a short hitch per pull rather than
-- a game at a fraction of its frame rate. The last PROBE line before a
-- shutdown names the call it happened in.
local light_until = -1
local light_last = {}          -- per-frame tag -> last write time
local LIGHT_FRAME_GAP = 0.05

-- Per-frame stages: written at most every LIGHT_FRAME_GAP. u:izi.on_update is
-- one of them and is NOT skipped (2.88.0) - it runs izi's spell queue, which
-- finishes casts, and the 16:40 shutdown came at the end of a Fireball.
local PER_FRAME = {
    ["u:begin"] = true, ["u:izi.on_update"] = true, ["u:keybinds"] = true,
    ["u:movement.pulse"] = true, ["on_render"] = true,
}

local function light_skip(tag)
    if tag == "-" or tag == "gui.draw" or tag:find("^gui:") then
        return true
    end
    if tag:find("^mv:") or PER_FRAME[tag] then
        local t = now_s()
        if (t - (light_last[tag] or -1)) < LIGHT_FRAME_GAP then
            return true
        end
        light_last[tag] = t
    end
    return false
end

--- Arm the light capture for `seconds` (extends, never shortens).
function errorlog.arm_light(seconds, why)
    local until_t = now_s() + (tonumber(seconds) or 1.5)
    if until_t > light_until then
        if light_until < now_s() then
            write("INFO", "light capture: " .. tostring(why))
        end
        light_until = until_t
    end
end

--- Arm (or extend) the recorder for another PROBE_WINDOW seconds.
function errorlog.arm(why)
    local until_t = now_s() + PROBE_WINDOW
    if until_t > probe_until then
        local was_on = probe_on
        probe_until = until_t
        probe_on = true
        -- Said once per window, not on every extension (a fight re-arms every tick).
        if not was_on then
            write("INFO", string.format("flight recorder armed for %ds: %s", PROBE_WINDOW, tostring(why)))
        end
    end
end

-- ----------------------------------------------------------------------------
-- PROFILER (2.28.0)
-- ----------------------------------------------------------------------------
-- The Plugin Monitor showed Master Farmer at 93 ms of Lua time a frame, 99% of
-- all plugins. core.time() only advances once a frame, so the recorder's
-- timestamps could not say where inside the frame that went. core.cpu_time()
-- is a nanosecond CPU clock: every probe point now adds the time since the
-- previous one to that stage's tally, in memory - no disk, one native call.
-- A PERF line every PERF_GAP seconds reports the plugin's CPU per frame and
-- the stages that cost the most.
--
-- errorlog.probe("-") marks the end of a callback: time from there to the
-- next probe belongs to the game and other plugins, not to a stage.
local cpu = nil
do
    local ok, fn = pcall(function() return core.cpu_time end)
    if ok and type(fn) == "function" then
        local ok2, v = pcall(fn)
        if ok2 and type(v) == "number" then
            cpu = fn
        end
    end
end
local PERF_GAP = 10
local perf = {}               -- tag -> { ns, n }
local perf_tag, perf_ns = nil, 0
local perf_frames = 0
local perf_next = 0

local function perf_mark(tag)
    local now = cpu()
    if perf_tag ~= nil and perf_tag ~= "-" then
        local e = perf[perf_tag]
        if e == nil then
            e = { 0, 0 }
            perf[perf_tag] = e
        end
        e[1] = e[1] + (now - perf_ns)
        e[2] = e[2] + 1
    end
    perf_tag, perf_ns = tag, now
end

local function perf_report()
    if perf_frames <= 0 then
        return
    end
    local list, total = {}, 0
    for tag, e in pairs(perf) do
        list[#list + 1] = { tag, e[1] }
        total = total + e[1]
    end
    table.sort(list, function(x, y) return x[2] > y[2] end)
    local parts = {}
    for i = 1, math.min(8, #list) do
        parts[#parts + 1] = string.format("%s %.2f", list[i][1], list[i][2] / 1e6 / perf_frames)
    end
    write("PERF", string.format("%.2f ms/frame over %d frames | %s",
        total / 1e6 / perf_frames, perf_frames, table.concat(parts, ", ")))
    perf = {}
    perf_frames = 0
end

--- Count a frame for the profiler. Called once per on_update.
function errorlog.frame()
    perf_frames = perf_frames + 1
end

--- A probe point: a profiler mark always, and a PROBE line while the
--- recorder is armed.
function errorlog.probe(tag)
    if cpu then
        perf_mark(tag)
    end
    if beat_on and beat_n < 48 and tag ~= "-" then
        beat_n = beat_n + 1
        beat_tags[beat_n] = (tag:gsub("^u:", ""))
    end
    if not probe_on then
        if light_until > 0 and now_s() <= light_until and not light_skip(tag) then
            write("PROBE", tag)
        end
        return
    end
    if now_s() > probe_until then
        probe_on = false
        write("INFO", "flight recorder window finished")
        return
    end
    -- The heap at each probe: a jump between two lines is what the stage in
    -- between allocated (less whatever the collector freed meanwhile).
    local ok, kb = pcall(collectgarbage, "count")
    if ok and type(kb) == "number" then
        write("PROBE", string.format("%-40s heap %.0f KB", tostring(tag), kb))
    else
        write("PROBE", tag)
    end
end

-- ----------------------------------------------------------------------------
-- HEARTBEAT (2.31.0)
-- ----------------------------------------------------------------------------
-- The full recorder writes ~25 lines a frame and slows the game enough that
-- the crash stops happening. The heartbeat writes ONE line per bot tick
-- (10 a second): the stages that tick ran through, and a short snapshot of
-- what the bot was doing. The last BEAT before a crash is the last complete
-- tick. Probe tags are only collected while a bot tick is open.
local beat_count = 0
local beat_extra = nil

--- A function returning a short status string for each BEAT line.
function errorlog.set_beat_extra(fn)
    beat_extra = fn
end

--- Open a bot tick: probe tags from here on are collected for its BEAT line.
function errorlog.tick_begin()
    beat_on = true
    beat_n = 0
end

--- Close the bot tick and write its BEAT line. No-op when none is open.
function errorlog.tick_end()
    if not beat_on then
        return
    end
    beat_on = false
    beat_count = beat_count + 1
    -- Heartbeat lines only with "Detailed session log" ticked (2.89.0): ten
    -- appends a second to a file OneDrive may be syncing is a suspect in the
    -- game shutdowns, so by default the log is quiet between trail lines.
    local g = package.loaded["gui"]
    if not (type(g) == "table" and type(g.is_on) == "function" and g.is_on("session_detail") == true) then
        return
    end
    local extra = ""
    if type(beat_extra) == "function" then
        local ok, s = pcall(beat_extra)
        if ok and type(s) == "string" then
            extra = s
        end
    end
    -- A tick identical to the last one is not written again for BEAT_SAME
    -- seconds (2.65.0): an idle bot wrote the same line ten times a second.
    -- The count of skipped ticks rides on the next line written, so the
    -- record still shows the bot was alive right up to its last line.
    local body = table.concat(beat_tags, ">", 1, beat_n) .. " | " .. extra
    local now = 0
    pcall(function() now = core.time() end)
    if body == beat_last_body and (now - beat_last_t) < BEAT_SAME then
        beat_same = beat_same + 1
        return
    end
    local same = beat_same > 0 and string.format(" (+%d same)", beat_same) or ""
    beat_last_body, beat_last_t, beat_same = body, now, 0
    write("BEAT", string.format("#%d %s%s", beat_count, body, same))
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
local mem_extra = nil

--- A function returning extra text for each MEM line (e.g. request counts).
function errorlog.set_mem_extra(fn)
    mem_extra = fn
end

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
    if cpu and type(now) == "number" and now >= perf_next then
        if perf_next > 0 then
            perf_report()
        end
        perf_next = now + PERF_GAP
    end
    if type(now) ~= "number" or now < mem_next then
        return
    end
    mem_next = now + MEM_GAP
    if kb then
        local extra = ""
        if type(mem_extra) == "function" then
            local ok, s = pcall(mem_extra)
            if ok and type(s) == "string" and s ~= "" then
                extra = "  " .. s
            end
        end
        write("MEM", string.format("lua heap %.0f KB  (peak %.0f KB)%s", kb, mem_peak, extra))
    end
end

--- Where this session's file is, for a status line.
function errorlog.path()
    return path and ("scripts_log/" .. path) or nil
end

return errorlog
