-- ============================================================================
-- Master Farmer - Grindbot
-- Per-character settings, saved to scripts_data/
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.9.1
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHAT THIS IS FOR, AND WHAT IT IS NOT FOR
--   core.menu elements already persist. Every checkbox, slider and combobox in
--   this plugin is created as core.menu.checkbox(default, id) and the loader
--   stores it against that id, so those come back on their own and are NOT
--   written here - duplicating them would mean two copies that disagree.
--
--   What does not survive is the state held in plain Lua tables, because it is
--   discovered at runtime and has no element behind it:
--
--     the chosen grind route   a route list that only exists after the
--                              catalog loads
--     the buff toggles         a spell list that only exists after the
--                              spellbook scan
--
--   Those are what this file keeps.
--
-- KEYED ON THE CHARACTER, NOT THE ACCOUNT
--   One file per GUID, and the GUID is also written inside it. The filename
--   alone would be enough in the normal case, but a file that gets copied or
--   renamed would then be applied to the wrong character, and a bot that
--   silently loads another character's route is worse than one that loads
--   nothing. The inside copy is checked before anything is applied.
--
-- THE FORMAT IS LINES, NOT LUA
--   `key=value`, one per line, with newlines and backslashes escaped in the
--   value. Reading a settings file must never be able to execute anything:
--   this file is on disk where other programs can edit it, and load()ing it
--   would turn "restore my settings" into "run whatever is in that file".
--   A line the parser does not understand is skipped, not fatal.
--
-- WRITING IS DEBOUNCED
--   Settings change on a click; a write is a disk hit. Changes mark the state
--   dirty and the tick flushes at most once every SAVE_GAP seconds, plus once
--   more when the bot stops.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local settings = {}

local FOLDER = "mfg"
local SAVE_GAP = 4.0
local FORMAT = 1

local loaded_for = nil       -- guid whose file has been applied
local dirty = false
local last_save = -1e9
local folder_ready = false

-- key -> { get = fun():string|nil, set = fun(value:string) }
local providers = {}
local order = {}

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- ESCAPING
-- ----------------------------------------------------------------------------
-- A value may contain anything a spell name may contain. Newlines would break
-- the line format and backslashes would break the unescaping, so both are
-- encoded; nothing else needs to be.
local function escape(v)
    v = tostring(v or "")
    v = v:gsub("\\", "\\\\")
    v = v:gsub("\n", "\\n")
    v = v:gsub("\r", "")
    return v
end

local function unescape(v)
    local out = {}
    local i = 1
    local n = #v
    while i <= n do
        local c = v:sub(i, i)
        if c == "\\" and i < n then
            local nxt = v:sub(i + 1, i + 1)
            if nxt == "n" then
                out[#out + 1] = "\n"
                i = i + 2
            elseif nxt == "\\" then
                out[#out + 1] = "\\"
                i = i + 2
            else
                out[#out + 1] = nxt
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- ----------------------------------------------------------------------------
-- IDENTITY
-- ----------------------------------------------------------------------------
--- The character's GUID, or nil while the player object is not ready.
local function guid_of(player)
    if not player then
        return nil
    end
    local g = safe(function() return player:get_guid() end)
    if type(g) == "string" and g ~= "" then
        return g
    end
    return nil
end

--- A GUID is "Player-970-0002FD41". Anything outside that shape is not put
--- into a path: a filename is the one place a surprising string becomes a
--- request to write somewhere unintended.
local function file_for(guid)
    local safe_name = tostring(guid):gsub("[^%w%-_]", "_")
    return FOLDER .. "/" .. safe_name .. ".txt"
end

-- ----------------------------------------------------------------------------
-- REGISTRATION
-- ----------------------------------------------------------------------------
--- Register one persisted value.
---
--- `get` returns a string to store, or nil to store nothing for this key.
--- `set` receives the stored string on load. Both are wrapped, so a provider
--- that throws costs its own key and not the whole file.
function settings.register(key, get, set)
    if type(key) ~= "string" or key == "" then
        return
    end
    if type(get) ~= "function" or type(set) ~= "function" then
        return
    end
    if not providers[key] then
        order[#order + 1] = key
    end
    providers[key] = { get = get, set = set }
end

--- Something changed; write it out on the next flush.
function settings.mark_dirty()
    dirty = true
end

-- ----------------------------------------------------------------------------
-- SERIALISE
-- ----------------------------------------------------------------------------
local function serialise(guid)
    local lines = {
        "# Master Farmer - Grindbot settings. Rewritten automatically.",
        "format=" .. tostring(FORMAT),
        "guid=" .. escape(guid),
    }
    for i = 1, #order do
        local key = order[i]
        local p = providers[key]
        if p then
            local value = safe(p.get)
            if type(value) == "string" and value ~= "" then
                lines[#lines + 1] = key .. "=" .. escape(value)
            end
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

local function parse(text)
    local out = {}
    if type(text) ~= "string" then
        return out
    end
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k then
                out[k] = unescape(v)
            end
        end
    end
    return out
end

-- ----------------------------------------------------------------------------
-- LOAD / SAVE
-- ----------------------------------------------------------------------------
local function ensure_folder()
    if folder_ready then
        return
    end
    folder_ready = true
    pcall(function() core.create_data_folder(FOLDER) end)
end

--- Read this character's file and apply it. Returns true when something was
--- applied, false when there was nothing to apply.
function settings.load(player)
    local guid = guid_of(player)
    if not guid then
        return false
    end
    if loaded_for == guid then
        return false
    end
    loaded_for = guid          -- one attempt per character, success or not

    ensure_folder()
    local path = file_for(guid)

    local size = safe(function() return core.get_data_file_size(path) end)
    if type(size) ~= "number" or size <= 0 then
        core.log("[Master Farmer - Grindbot] No saved settings for this character yet.")
        return false
    end

    local text = safe(function() return core.read_data_file(path) end)
    if type(text) ~= "string" or text == "" then
        return false
    end

    local data = parse(text)

    -- The GUID inside the file has to match. A copied or renamed file would
    -- otherwise apply another character's route and buffs to this one.
    if data.guid ~= guid then
        core.log_warning(string.format(
            "[Master Farmer - Grindbot] %s belongs to %s, not this character. Ignoring it.",
            path, tostring(data.guid)))
        return false
    end

    local applied = 0
    for i = 1, #order do
        local key = order[i]
        local value = data[key]
        if value ~= nil and providers[key] then
            local ok = pcall(providers[key].set, value)
            if ok then
                applied = applied + 1
            else
                core.log_warning("[Master Farmer - Grindbot] settings: could not apply " .. key)
            end
        end
    end

    core.log(string.format("[Master Farmer - Grindbot] Restored %d setting group(s) for this character.", applied))
    dirty = false
    return applied > 0
end

--- Write this character's file now.
function settings.save(player)
    local guid = guid_of(player)
    if not guid then
        return false
    end
    ensure_folder()
    local path = file_for(guid)
    local body = serialise(guid)

    -- create_data_file is a no-op when the file already exists on the loaders
    -- that implement it that way, and write_data_file overwrites - so this is
    -- safe to call every time rather than tracking whether it exists.
    pcall(function() core.create_data_file(path) end)
    local ok = pcall(function() core.write_data_file(path, body) end)
    if ok then
        dirty = false
        last_save = izi.now()
        return true
    end
    core.log_warning("[Master Farmer - Grindbot] could not write " .. path)
    return false
end

--- Load once, then flush when something changed. Cheap enough for every tick.
function settings.tick(player)
    if not player then
        return
    end
    if loaded_for == nil then
        settings.load(player)
        return
    end
    if not dirty then
        return
    end
    local now = izi.now()
    if (now - last_save) < SAVE_GAP then
        return
    end
    settings.save(player)
end

--- Forget which character was loaded, so a character swap re-reads.
function settings.reset()
    loaded_for = nil
    dirty = false
end

--- The file this character would use, for a status line.
function settings.path_for(player)
    local guid = guid_of(player)
    if not guid then
        return nil
    end
    return file_for(guid)
end

return settings
