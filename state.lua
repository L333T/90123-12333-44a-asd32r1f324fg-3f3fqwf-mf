-- ============================================================================
-- Master Farmer - Grindbot
-- Shared runtime state (no leaked globals)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.273.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local state = {
    note = "",
    note_head = "",
    cached_pos = nil,
    cached_now = 0,
    last_action = "Idle",
}

state.grind = {
    step = 1,
    move = 1,
    finished = false,        -- 2.151.0: a non-loop profile reached its last node
    scan_until = 0,
    black_until = 0,
    killed = {},
    killed_order = {},
    killed_reset = 0,
}

state.target = {
    unit = nil,
    guid = nil,
    x = nil,
    y = nil,
    z = nil,
    kind = nil,
}

state.dead = {
    released_at = 0,
    waiting = false,
    corpse = nil,
    retrieve_at = 0,
}

state.combat = {
    -- kiting is owned by movement.lua's combat controller, not by the rotation
    nova_at = 0,
    face_at = 0,
    unreachable = {},
}

state.quest = {
    id = nil,
    step = 1,
    interact_until = 0,
    skipped = {},
}

state.vendor = {
    active = false,
    repaired = false,
    sold = 0,
    interact_until = 0,
    done_until = 0,
    lack_gold = 0,
    wait_npc = 0,
    tries = 0,
}

local last_printed_note = ""
local last_printed_action = ""

local function console_on()
    local ok, gui = pcall(require, "gui")
    if not ok or not gui or type(gui.is_on) ~= "function" then
        return false
    end
    return gui.is_on("print_action") == true
end

local function console_print(text)
    if type(izi.print) ~= "function" then
        return
    end
    pcall(izi.print, "[Master Farmer] ", text)
end

-- The General tab toggle. A repeat of the same line is not printed again.
function state.report_action(text)
    if type(text) ~= "string" or text == "" then
        return
    end
    if not console_on() then
        last_printed_action = ""
        return
    end
    if text == last_printed_action then
        return
    end
    last_printed_action = text
    console_print(text)
end

function state.set_note(head, text)
    state.note_head = head or ""
    state.note = text or ""
    local line
    if state.note_head ~= "" and state.note ~= "" then
        line = state.note_head .. ": " .. state.note
    elseif state.note ~= "" then
        line = state.note
    else
        line = state.note_head
    end
    if line == "" then
        return
    end
    if not console_on() then
        last_printed_note = ""
        return
    end
    if line == last_printed_note then
        return
    end
    last_printed_note = line
    console_print(line)
end

-- ONE CURRENT TARGET (2.143.0). state.target is the authority. Other
-- copies (combat.lua's hold latch) register here so clearing the target
-- clears them too - a target an engine dropped (unreachable, released) was
-- otherwise still held by the latch and could be picked up again by a caller
-- that passes no target (Rotation Only).
state.on_target_reset = {}

function state.reset_target()
    state.target.unit = nil
    state.target.guid = nil
    state.target.x = nil
    state.target.y = nil
    state.target.z = nil
    state.target.kind = nil
    for i = 1, #state.on_target_reset do
        pcall(state.on_target_reset[i])
    end
end

local KILLED_MAX = 48

local function guid_key(guid)
    if guid == nil then
        return nil
    end
    local t = type(guid)
    if t == "string" then
        if guid == "" then
            return nil
        end
        return guid
    end
    if t == "number" then
        return tostring(guid)
    end
    local ok, text = pcall(tostring, guid)
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return nil
end

function state.mark_killed(guid)
    local key = guid_key(guid)
    if not key then
        return
    end
    local killed = state.grind.killed
    if killed[key] then
        return
    end
    killed[key] = true
    local order = state.grind.killed_order
    if type(order) ~= "table" then
        order = {}
        state.grind.killed_order = order
    end
    order[#order + 1] = key
    while #order > KILLED_MAX do
        local old = table.remove(order, 1)
        if old then
            killed[old] = nil
        end
    end
end

-- Mobs the bot has targeted to kill, GUID -> when (2.48.0). The loot scan
-- treats a corpse from this list as the bot's own kill.
state.engaged = {}
local ENGAGED_TTL = 300

function state.note_engaged(guid)
    local key = guid_key(guid)
    if not key then
        return
    end
    local now = 0
    pcall(function() now = core.time() end)
    state.engaged[key] = now
    -- Keep it small: drop anything older than the TTL now and then.
    local n = 0
    for _ in pairs(state.engaged) do n = n + 1 end
    if n > 64 then
        for k, t in pairs(state.engaged) do
            if (now - t) > ENGAGED_TTL then
                state.engaged[k] = nil
            end
        end
    end
end

function state.was_engaged(guid)
    local key = guid_key(guid)
    local t = key and state.engaged[key]
    if not t then
        return false
    end
    local now = 0
    pcall(function() now = core.time() end)
    return (now - t) <= ENGAGED_TTL
end

function state.was_killed(guid)
    local key = guid_key(guid)
    if not key then
        return false
    end
    return state.grind.killed[key] == true
end

local UNREACH_TTL = 45.0

local function now_s()
    local ok, t = pcall(function()
        return core.time()
    end)
    if ok and type(t) == "number" then
        return t
    end
    return 0
end

function state.mark_unreachable(guid)
    local key = guid_key(guid)
    if not key then
        return
    end
    if type(state.combat.unreachable) ~= "table" then
        state.combat.unreachable = {}
    end
    state.combat.unreachable[key] = now_s()
end

function state.is_unreachable(guid)
    local key = guid_key(guid)
    if not key then
        return false
    end
    local bag = state.combat.unreachable
    if type(bag) ~= "table" then
        return false
    end
    local stamped = bag[key]
    if type(stamped) ~= "number" then
        return false
    end
    if (now_s() - stamped) > UNREACH_TTL then
        bag[key] = nil
        return false
    end
    return true
end

return state
