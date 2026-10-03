-- ============================================================================
-- Master Farmer - Grindbot
-- Gossip options - find and select an NPC's option by icon, type or wording
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.204.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- ONE WAY TO PICK A GOSSIP OPTION (2.144.0). Four modules each found and
-- selected options their own way, and two of them (trainer before 2.125.0,
-- vendor until now) read `gossip_option_id` from izi's option VIEW - a field a
-- view does not have - so izi's icon match was always thrown away and only
-- the raw gossip_type test was left, which Blizzard's Classic clients do not
-- always fill in.
--
-- Order, per the API docs (izi.gossip normalises retail and the private-server
-- clients; see quests "GOSSIP DIFFERS BY GAME VERSION"):
--   1. izi.gossip.find_option_by_icon(izi.gossip.ICON[spec.icon]) - selected
--      with the view's own :select();
--   2. the raw core.quests.get_gossip_options() rows, matched by gossip_type,
--      icon number or wording, selected by gossip_option_id (a real id on
--      Blizzard clients, the 1-based row on the private-server ones). The id
--      is used straight away and never stored.
--
-- spec = {
--   icon     = "TRAINER" | "VENDOR" | "TAXI" | "BINDER" | ...  (izi.gossip.ICON key)
--   icon_num = number     raw icon to accept when izi has no ICON table
--   type     = "trainer"  raw gossip_type to accept
--   words    = { ... }    lower-case words the option text may contain
-- }
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gossip = {}

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

--- Is a gossip frame open?
function gossip.is_open()
    local g = izi.gossip
    if type(g) == "table" and type(g.is_open) == "function" then
        if safe(function() return g.is_open() end) == true then
            return true
        end
    end
    return safe(function() return core.quests.is_gossip_frame_shown() end) == true
end

--- Close the gossip frame.
function gossip.close()
    local g = izi.gossip
    if type(g) == "table" and type(g.close) == "function" then
        pcall(function() g.close() end)
    end
    pcall(function() core.quests.close_gossip() end)
end

local function wording_matches(name, words)
    if type(words) ~= "table" or type(name) ~= "string" then return false end
    local text = string.lower(name)
    for i = 1, #words do
        if text:find(words[i], 1, true) then return true end
    end
    return false
end

local function izi_icon(spec)
    local g = izi.gossip
    if type(spec.icon) == "string" and type(g) == "table" and type(g.ICON) == "table"
        and type(g.ICON[spec.icon]) == "number" then
        return g.ICON[spec.icon]
    end
    return spec.icon_num
end

--- The open frame's option matching `spec`, as (select_function, label), or nil.
function gossip.find(spec)
    if type(spec) ~= "table" then return nil end
    local g = izi.gossip
    local icon = izi_icon(spec)
    -- 1. izi's normalised view, by icon.
    if icon and type(g) == "table" and type(g.find_option_by_icon) == "function" then
        local view = safe(function() return g.find_option_by_icon(icon) end)
        if type(view) == "table" and type(view.select) == "function" then
            return function() view:select() end, tostring(view.name or spec.icon or "option")
        end
    end
    local function wanted(opt)
        local gtype = type(opt.gossip_type) == "string" and string.lower(opt.gossip_type) or ""
        return (spec.type and gtype == spec.type)
            or (icon and opt.icon == icon and icon ~= 0)
            or wording_matches(opt.name, spec.words)
    end
    -- 1b. izi's views by type / icon / wording, still selected by the view.
    if type(g) == "table" and type(g.options) == "function" then
        local views = safe(g.options)
        if type(views) == "table" then
            for i = 1, #views do
                local v = views[i]
                if type(v) == "table" and type(v.select) == "function" and wanted(v) then
                    return function() v:select() end, tostring(v.name or "option")
                end
            end
        end
    end
    -- 2. The raw rows: type, icon number or wording.
    local options = safe(function() return core.quests.get_gossip_options() end)
    if type(options) ~= "table" then return nil end
    for i = 1, #options do
        local opt = options[i]
        if type(opt) == "table" then
            if wanted(opt) then
                local id = opt.gossip_option_id
                if type(id) ~= "number" or id == 0 then id = i end
                return function() core.quests.select_gossip_option(id) end, tostring(opt.name)
            end
        end
    end
    return nil
end

--- Select the option matching `spec`. Returns true, label when one was sent.
function gossip.select(spec)
    local fn, label = gossip.find(spec)
    if not fn then return false end
    pcall(fn)
    return true, label
end

return gossip
