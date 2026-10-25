-- ============================================================================
-- restedXP_questing
-- quest/objguard.lua - world objects that crash the game when used
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.29.0
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
-- 4.27.0 (user: "Check crash logs and correct crashing issue"): the 03:05
-- crash left the journal "interact|joseph redpath's monument" - use_object
-- was NOT accepted (4 yd: not yet in reach) and the old fallback,
-- core.input.interact_with_object on a WORLD OBJECT, is what died. The 4.22
-- Pamela's Doll crashes went the same way (use_object, then the same
-- fallback). So: a world object (not a unit) gets use_object ONLY - never
-- interact_with_object; not accepted = "refused" (the caller steps closer and
-- tries again). Units (NPCs) keep interact_with_object. The journal guards
-- use_object: an object it crashed on is skipped for good. The 4.23 seed
-- (Doll pieces -> interact) is gone - it pointed at the call that crashed.
-- Names are compared lower-case.
-- ============================================================================

local O = {}

local FOLDER = "mfg"
local OBJGUARD_FILE = FOLDER .. "/objguard_pending.txt"
local CRASH_FILE = FOLDER .. "/objguard_crashed.txt"
O.CLEAR_S = 4.0

local SEED = {}

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

local function is_unit(obj)
    return safe(function() return obj:is_unit() end) == true
end

--- The safe call for `obj`: "interact" for a unit (an NPC), "use" for a world
--- object, nil when use_object crashed the game on it before (skip it).
function O.method(obj)
    load()
    if is_unit(obj) then return "interact" end
    local n = name_of(obj)
    local e = n and crashed[n] or nil
    if not e or not e.use then return "use" end
    if n and not said[n] then
        said[n] = true
        warn("'" .. n .. "' crashed the game with use_object - skipped; open it by hand")
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

-- 4.28.0 INTERACTION LOCK (user: "When interacting with a object, pause ALL
-- other actions if enemy target attacks stop interacting kill enemy target or
-- targets then begin interacting with object again until step is complete").
-- An accepted use_object locks for LOCK_S s, kept on while the player casts /
-- channels (the "Opening" cast) or a loot window is open. While locked,
-- main.lua runs nothing but the quest step - no other corpses, conjure,
-- rest, buffs, trainer, vendor or equip. Anything attacking the player or the
-- pet (or the player in combat) releases it at once: the quest engine's
-- fight-back kills the attackers, then the step's object goal (still not
-- complete) opens the object again - and locks again.
O.LOCK_S = 8.0
local lock = nil            -- { t, name, until_t }

--- Is an object interaction holding every other action off?
function O.locked()
    return lock ~= nil and now() < lock.until_t
end

--- End the lock (attacked, goal done ...).
function O.release(why)
    if lock then
        local el = package.loaded["errorlog"]
        if type(el) == "table" and type(el.trail) == "function" then
            pcall(el.trail, "act", "object interaction with %s released: %s", tostring(lock.name), tostring(why))
        end
    end
    lock = nil
end

--- Every tick: a journal entry older than CLEAR_S s is cleared (the call lived);
--- the interaction lock is kept on while the open is still running.
function O.tick(player)
    if pending and (now() - pending.t) >= O.CLEAR_S then
        pending = nil
        write(OBJGUARD_FILE, "")
    end
    if lock then
        local t = now()
        if t >= lock.until_t then lock = nil return end
        local casting = player and safe(function() return player:is_channeling_or_casting() end) == true
        local n = safe(function() return core.game_ui.get_loot_item_count() end)
        if casting or (type(n) == "number" and n > 0) then
            lock.until_t = math.max(lock.until_t, t + 2.0)
        end
    end
end

--- Open `obj` the safe way. Returns sent, how: true + "use" / "interact";
--- false + "refused" (use_object not accepted - step closer, try again);
--- false + "crashed before - skipped".
function O.open(obj)
    local m = O.method(obj)
    if not m then return false, "crashed before - skipped" end
    if m == "interact" then                       -- a unit (NPC): the normal interact
        pcall(function() core.input.interact_with_object(obj) end)
        return true, m
    end
    O.before(obj, "use")
    local ok = safe(function() return core.input.use_object(obj) end)
    if ok == true then
        lock = { t = now(), name = name_of(obj), until_t = now() + O.LOCK_S }      -- 4.28.0
        return true, "use"
    end
    -- NEVER interact_with_object on a world object (4.27.0): the call that crashed
    pending = nil
    write(OBJGUARD_FILE, "")
    return false, "refused"
end

function O._reset() crashed, pending, said, lock = nil, nil, {}, nil end

return O
