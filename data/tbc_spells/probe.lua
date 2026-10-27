-- ============================================================================
-- TBC spell ids to probe (GENERATED - tools/gen_tbc_spells.py, do not edit)
-- ============================================================================
-- M.ids(class_id, race_id): every spell id of this class (Mage conjures and
-- Shaman totems included) plus this race's racials for the class, for the
-- spellbook scan to ask has_spell / is_spell_learned / is_spell_known about.
--
-- Only this character's class file and the racial table are ever loaded, each
-- once, and their modules are freed straight after: the ids are kept in one
-- flat list. A class or race the client does not report yet (nil / 0) is tried
-- again on the next call.
-- ============================================================================

local M = {}

local PREFIX = "data/tbc_spells/"
local CLASS_FILE = { [1] = "warrior", [2] = "paladin", [3] = "hunter", [4] = "rogue", [5] = "priest",
    [7] = "shaman", [8] = "mage", [9] = "warlock", [11] = "druid" }

local ids = {}
local seen = {}
local class_done = false
local race_done = false

local function take(name)
    local ok, data = pcall(require, name)
    if type(package) == "table" then
        if type(package.loaded) == "table" then package.loaded[name] = nil end
        if type(package.preload) == "table" then package.preload[name] = nil end
    end
    if ok and type(data) == "table" then return data end
    return nil
end

local function add(id)
    if type(id) == "number" and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
    end
end

--- The ids to probe for this class and race (a shared list - read only).
function M.ids(class_id, race_id)
    local file = CLASS_FILE[class_id]
    if not class_done and file then
        class_done = true
        local rows = take(PREFIX .. file)
        if rows then
            for i = 1, #rows do add(rows[i][1]) end
        end
    end
    if not race_done and file and type(race_id) == "number" and race_id > 0 then
        race_done = true
        local all = take(PREFIX .. "racials")
        local list = all and all[race_id]
        if type(list) == "table" then
            for i = 1, #list do
                local classes = list[i][2]
                local fits = classes == nil
                if not fits then
                    for k = 1, #classes do
                        if classes[k] == class_id then fits = true end
                    end
                end
                if fits then add(list[i][1]) end
            end
        end
    end
    return ids
end

return M
