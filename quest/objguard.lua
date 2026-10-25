-- ============================================================================
-- restedXP_questing
-- quest/objguard.lua - world objects that crash the game when used
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.26.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.23.0 (user: "Check logs for what is causing disconnection during
-- questing" / "Crashed again"). Three sessions on 2026-10-25 (02:45:02,
-- 02:45:33, 02:46:59) died the same way: "open pamela's doll's left / right
-- side" (core.input.use_object) and 0.6-5 s later the player object was gone
-- ("hp ?"), then a loading screen - no WoW crash report, the native call
-- itself. 2.299.0 met the same with a Forge and a Campfire (OX.FOCUS). A name
-- list only covers the objects already met, so the guard is general:
--   * O.before(obj, method) writes "<method>|<name>" to OBJGUARD_FILE just
--     before the call; O.tick() clears it CLEAR_S s later (the game lived);
--   * at load, an entry still there = that call on that object crashed the
--     game: the method is remembered for the name (CRASH_FILE, kept across
--     sessions) and logged;
--   * O.method(obj): the call to use - "use" (use_object), "interact"
--     (interact_with_object) once "use" crashed on it, nil once both did (the
--     object is skipped; the note says to open it by hand).
-- SEEDED with the three Pamela's Doll pieces (use_object crashed 3 times).
-- Names are compared lower-case.
-- ============================================================================

local O = {}

local FOLDER = "mfg"
local OBJGUARD_FILE = FOLDER .. "/objguard_pending.txt"
local CRASH_FILE = FOLDER .. "/objguard_crashed.txt"
O.CLEAR_S = 4.0

local SEED = {
    ["pamela's doll's left side"] = { use = true },
    ["pamela's doll's right side"] = { use = true },
    ["pamela's doll's head"] = { use = true },
}

local crashed = nil        -- name -> { use = true, interact = true }
local pending = nil        -- { t, name, method } written to the file
local said = {}

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local t = ok and type(izi) == "table" and safe(izi.now) or nil
    return type(t) == "number" and t or 0
end

local function log(s) pcall(core.log, "[restedXP_questing] " .. s) end
local function warn(s) pcall(core.log_warning, "[restedXP_questing] " .. s) end

local function name_of(obj)
    local n = obj and safe(function() return obj:get_name() end) or nil
    return type(n) == "string" and string.lower(n) or nil
end

local function write(file, text)
    pcall(core.create_data_folder, FOLDER)
    pcall(core.create_data_file, file)
    if text and text ~= "" then pcall(core.write_data_file, file, text) end
end

local function save_crashed()
    local lines = {}
    for n, m in pairs(crashed) do
        if not SEED[n] or m.interact then
            lines[#lines + 1] = (m.use and "use" or "") .. "," .. (m.interact and "interact" or "") .. "|" .. n
        end
    end
    table.sort(lines)
    write(CRASH_FILE, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

--- Load the crash list, and turn a pending entry left by the last session
--- (the game died during that call) into a crash record.
local function load()
    if crashed then return end
    crashed = {}
    for n, m in pairs(SEED) do crashed[n] = { use = m.use, interact = m.interact } end
    local body = safe(core.read_data_file, CRASH_FILE)
    if type(body) == "string" then
        for line in body:gmatch("[^\n]+") do
            local ms, n = line:match("^([%a,]*)|(.+)$")
            if n then
                local e = crashed[n] or {}
                if ms:find("use", 1, true) then e.use = true end
                if ms:find("interact", 1, true) then e.interact = true end
                crashed[n] = e
            end
        end
    end
    local p = safe(core.read_data_file, OBJGUARD_FILE)
    if type(p) == "string" then
        local method, n = p:match("^(%a+)|([^\n]+)")
        if method and n then
            local e = crashed[n] or {}
            e[method] = true
            crashed[n] = e
            warn(string.format("the game died while %s '%s' was in progress last session - %s",
                method == "use" and "use_object on" or "interact_with_object on", n,
                (e.use and e.interact) and "never touched again (open it by hand)" or "the other way is tried next time"))
            save_crashed()
        end
        write(OBJGUARD_FILE, "")
    end
end

--- The safe call for `obj`: "use", "interact", or nil (both crashed: skip it).
function O.method(obj)
    load()
    local n = name_of(obj)
    local e = n and crashed[n] or nil
    if not e then return "use" end
    if not e.use then return "use" end
    if not e.interact then return "interact" end
    if n and not said[n] then
        said[n] = true
        warn("'" .. n .. "' crashed the game with use_object and interact_with_object - skipped; open it by hand")
    end
    return nil
end

--- Is `obj` banned outright (both calls crashed)?
function O.banned(obj) return O.method(obj) == nil end

--- Just before the call: journal it.
function O.before(obj, method)
    load()
    local n = name_of(obj)
    if not n then return end
    pending = { t = now(), name = n, method = method }
    write(OBJGUARD_FILE, method .. "|" .. n .. "\n")
end

--- Every tick: a journal entry older than CLEAR_S s is cleared (the call lived).
function O.tick()
    if pending and (now() - pending.t) >= O.CLEAR_S then
        pending = nil
        write(OBJGUARD_FILE, "")
    end
end

--- Open `obj` the safe way: journal + the right call. true when a call went out.
function O.open(obj)
    local m = O.method(obj)
    if not m then return false, "both ways crashed the game - skipped" end
    O.before(obj, m)
    if m == "use" then
        local ok = safe(function() return core.input.use_object(obj) end)
        if ok == true then return true, m end
        -- not accepted: the other call, journalled as such
        O.before(obj, "interact")
        pcall(function() core.input.interact_with_object(obj) end)
        return true, "interact"
    end
    pcall(function() core.input.interact_with_object(obj) end)
    return true, m
end

function O._reset() crashed, pending, said = nil, nil, {} end

return O
