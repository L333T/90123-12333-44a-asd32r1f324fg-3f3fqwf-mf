-- ============================================================================
-- Master Farmer - Grindbot
-- Spell picks - what the Spells tab has switched on
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.8.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- One registry of "the user ticked this spell", keyed by spell NAME, filled
-- from the Spells tab and read by the rotations.
--
-- WHY NAMES AND NOT MENU IDS
--   The spell list is discovered at runtime by the scanner, while the menu's
--   elements are registered at load. A menu id can only exist for a spell
--   someone wrote a checkbox for; a name exists for everything in the book.
--   This is the same mismatch that made the route index unreachable in 1.9.3.
--
-- THREE STATES, NOT TWO
--   state(name) answers true, false, or NIL - and nil is the important one.
--   It means "the user has not touched this", which is different from "the
--   user switched it off". A rotation asks wants(name, default) and keeps its
--   own default until someone actually makes a choice in the Spells tab, so
--   adding the tab did not silently re-arm or disarm anything that was
--   already working.
--
-- ONE REGISTRY
--   buffs.lua used to keep its own copy of this table. Two registries of the
--   same fact can only drift apart, and the one the user could see was not
--   always the one the bot read, so buffs.lua now delegates here.
-- ============================================================================

local picks = {}

-- name -> true / false. A name that is absent has never been chosen.
local chosen = {}

--- What the user has said about this spell: true, false, or nil for untouched.
function picks.state(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return chosen[name]
end

--- Has the user explicitly switched this on?
function picks.is_enabled(name)
    return picks.state(name) == true
end

--- Should this spell be used? `default` is what the rotation wants when the
--- user has expressed no opinion.
function picks.wants(name, default)
    local st = picks.state(name)
    if st == nil then
        return default == true
    end
    return st
end

function picks.set(name, on)
    if type(name) ~= "string" or name == "" then
        return
    end
    chosen[name] = (on == true)
end

--- Back to "untouched", so the rotation's own default applies again.
function picks.clear(name)
    if type(name) == "string" then
        chosen[name] = nil
    end
end

--- Cycle on -> off -> untouched. Three states need three stops, or there is
--- no way back to "let the rotation decide" once a row has been clicked.
function picks.cycle(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local st = chosen[name]
    if st == nil then
        chosen[name] = true
    elseif st == true then
        chosen[name] = false
    else
        chosen[name] = nil
    end
    return chosen[name]
end

--- Plain two-state toggle, for callers that do not want the untouched stop.
function picks.toggle(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    chosen[name] = not (chosen[name] == true)
    return chosen[name]
end

function picks.count()
    local on, off = 0, 0
    for _, v in pairs(chosen) do
        if v == true then
            on = on + 1
        else
            off = off + 1
        end
    end
    return on, off
end

-- ----------------------------------------------------------------------------
-- PERSISTENCE
-- ----------------------------------------------------------------------------
-- Two lines, one for the on names and one for the off names, because "off"
-- has to survive a reload as distinctly as "on" does - a spell the user
-- deliberately switched off must not come back as the rotation's default.

local SEP = "\n"

function picks.serialise()
    local on, off = {}, {}
    for name, v in pairs(chosen) do
        if v == true then
            on[#on + 1] = name
        else
            off[#off + 1] = name
        end
    end
    table.sort(on)
    table.sort(off)
    return table.concat(on, SEP) .. "\t" .. table.concat(off, SEP)
end

function picks.deserialise(text)
    chosen = {}
    if type(text) ~= "string" or text == "" then
        return
    end
    local on_part, off_part = text:match("^(.-)\t(.*)$")
    if not on_part then
        -- A file written before the off list existed: everything in it was on.
        on_part, off_part = text, ""
    end
    for name in on_part:gmatch("[^\n]+") do
        chosen[name] = true
    end
    for name in off_part:gmatch("[^\n]+") do
        chosen[name] = false
    end
end

function picks.reset()
    chosen = {}
end

return picks
