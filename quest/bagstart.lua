-- ============================================================================
-- Master Farmer - quests started from bag items (bagstart)
-- ============================================================================
-- User 2026-10-27: "requires using item from bag to begin a quest. Add logic to
-- ensure all Zygor, restedXP, Forever_Questing completes the steps that require
-- using items from inventory for completing quest tasks OR starting quests."
-- Log 14:17 (Zygor step 93 "kill "Count" Ungula / get "Count" Ungula's Mandible
-- / use it / accept 9911"): the use goal names no item and the Mandible (25459)
-- has NO use spell - an item that begins a quest never has one - so the bag's
-- quest-item list (spell items only) held only Two of Beasts (19230), used 8x a
-- minute for 14 minutes while the quest was never offered.
--
-- An item that starts a quest: a bag item of item class 12 / item type "Quest"
-- with no use spell (core.quests.get_item_info / get_item_spell). The step's own
-- items (its loot / use goals) are tried first. Using one opens the quest panel
-- (core.quests.get_open_quest_info): the wanted quest is accepted
-- (accept_quest + confirm_accept_quest), another quest's panel is declined and
-- that item ruled out for this quest. Same file in zygor_questing,
-- restedXP_questing_sentinel and forever_questing (each product its own copy).
--   BS.starters()                       bag item ids that may start a quest
--   BS.usable_quest_items()             bag quest items WITH a use spell
--   BS.panel()                          { quest_id, title } of the open quest panel, or nil
--   BS.accept_open(qids, title)         accept the open panel when it is one of `qids`
--   BS.start(qid, prefer, title)        "accepted" | "using" | nil (nothing left to try)
-- ============================================================================

local BS = {}

BS.TTL = 2.0              -- s between two bag reads
BS.TRY_GAP = 3.0          -- s between two uses (the panel opens in well under that)
BS.TRIES = 2              -- uses of one item before it is ruled out for a quest
local CLASS_QUEST = 12
local HEARTHSTONE = 6948

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local t = safe(izi.now)
        if type(t) == "number" then return t end
    end
    return 0
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "act", fmt, ...) end
end

-- ----------------------------------------------------------------------------
-- the bags
-- ----------------------------------------------------------------------------
local memo = {}           -- item id -> { quest, spell, name }
local bag = { t = -1e9, count = {}, ids = {} }

local function facts(id)
    local f = memo[id]
    if f then return f end
    local info = safe(core.quests.get_item_info, id)
    local sp = safe(core.quests.get_item_spell, id)
    local spell_id = type(sp) == "table" and tonumber(sp.spell_id) or nil
    f = {
        quest = type(info) == "table" and (tonumber(info.class_id) == CLASS_QUEST or info.item_type == "Quest") or false,
        spell = (spell_id and spell_id > 0) and spell_id or nil,
        name = type(info) == "table" and type(info.name) == "string" and info.name or nil,
    }
    -- an item the client has not loaded yet answers nil: asked again next time
    if type(info) == "table" then memo[id] = f end
    return f
end
BS.facts = facts

local function read_bags()
    local t = now()
    if t - bag.t < BS.TTL then return bag end
    bag.t, bag.count, bag.ids = t, {}, {}
    for b = 0, 4 do
        local items = safe(function() return core.inventory.get_items_in_bag(b) end)
        if type(items) == "table" then
            for i = 1, #items do
                local e = items[i]
                local id = type(e) == "table" and e.object and safe(function() return e.object:get_item_id() end)
                if type(id) == "number" and id > 0 then
                    if not bag.count[id] then bag.ids[#bag.ids + 1] = id end
                    bag.count[id] = (bag.count[id] or 0) + 1          -- slots holding it
                end
            end
        end
    end
    table.sort(bag.ids)
    return bag
end

--- Is item `id` in the bags?
function BS.has(id)
    id = tonumber(id)
    return id ~= nil and (read_bags().count[id] or 0) > 0
end

--- Bag items that may start a quest: quest class / type, no use spell.
function BS.starters()
    local out, b = {}, read_bags()
    for i = 1, #b.ids do
        local id = b.ids[i]
        local f = facts(id)
        if f.quest and not f.spell and id ~= HEARTHSTONE then out[#out + 1] = id end
    end
    return out
end

--- Bag quest items with a use spell (the items used ON quest objectives).
function BS.usable_quest_items()
    local out, b = {}, read_bags()
    for i = 1, #b.ids do
        local id = b.ids[i]
        local f = facts(id)
        if f.quest and f.spell and id ~= HEARTHSTONE then out[#out + 1] = id end
    end
    return out
end

-- ----------------------------------------------------------------------------
-- the quest panel
-- ----------------------------------------------------------------------------
function BS.panel()
    if type(core.quests.get_open_quest_info) ~= "function" then return nil end
    local info = safe(function() return core.quests.get_open_quest_info() end)
    if type(info) ~= "table" then return nil end
    return { title = type(info.title) == "string" and info.title or "", quest_id = tonumber(info.quest_id) or 0 }
end

local function panel_matches(p, qids, title)
    if not p then return false end
    if type(qids) == "table" and qids[p.quest_id] then return true end
    -- quest_id 0: the client could not attach an id - the title decides
    if p.quest_id == 0 and type(title) == "string" and title ~= "" and p.title ~= "" then
        return string.lower(p.title) == string.lower(title)
    end
    return false
end

--- Accept the open quest panel when it shows one of `qids` (a set). true when accepted.
function BS.accept_open(qids, title)
    local p = BS.panel()
    if not panel_matches(p, qids, title) then return false end
    pcall(function() core.quests.accept_quest() end)
    pcall(function() core.quests.confirm_accept_quest() end)
    trail("quest panel %d '%s' accepted", p.quest_id, tostring(p.title))
    return true
end

-- ----------------------------------------------------------------------------
-- starting a quest from an item
-- ----------------------------------------------------------------------------
local st = { qid = nil }

--- One action toward quest `qid` from the bags. `prefer`: item ids to try first
--- (the step's own items; any class). Returns "accepted", "using" (an item was
--- used or its panel is awaited) or nil (no item left to try for this quest).
function BS.start(qid, prefer, title)
    qid = tonumber(qid)
    if not qid then return nil end
    if safe(function() return core.quests.is_on_quest(qid) end) == true then return nil end
    local t = now()
    if st.qid ~= qid then st = { qid = qid, out = {}, cur = nil, n = 0, t = -1e9 } end
    local p = BS.panel()
    if panel_matches(p, { [qid] = true }, title) then
        pcall(function() core.quests.accept_quest() end)
        pcall(function() core.quests.confirm_accept_quest() end)
        trail("quest %d accepted from item %s", qid, tostring(st.cur))
        return "accepted"
    end
    if p and st.cur and t - st.t < BS.TRY_GAP + 2 then
        -- the item opened another quest: not the one wanted
        pcall(function() core.quests.decline_quest() end)
        trail("item %d offers quest %d '%s', not %d - declined, item ruled out", st.cur, p.quest_id,
            tostring(p.title), qid)
        st.out[st.cur], st.cur = true, nil
        return "using"
    end
    if st.cur and t - st.t < BS.TRY_GAP then return "using" end
    if st.cur and st.n >= BS.TRIES then
        trail("item %d used %d times, no panel for quest %d - item ruled out", st.cur, st.n, qid)
        st.out[st.cur], st.cur = true, nil
    end
    if not st.cur then
        local cands, seen = {}, {}
        for _, id in ipairs(prefer or {}) do
            id = tonumber(id)
            if id and not seen[id] and BS.has(id) and id ~= HEARTHSTONE then seen[id] = true cands[#cands + 1] = id end
        end
        for _, id in ipairs(BS.starters()) do
            if not seen[id] then seen[id] = true cands[#cands + 1] = id end
        end
        for i = 1, #cands do
            if not st.out[cands[i]] then st.cur, st.n = cands[i], 0 break end
        end
        if not st.cur then return nil end
    end
    st.n, st.t = st.n + 1, t
    local used = safe(function() return core.input.use_item(st.cur) end)
    trail("quest %d: using item %d '%s' to start it (try %d)%s", qid, st.cur, tostring(facts(st.cur).name),
        st.n, used == false and " - refused" or "")
    return "using"
end

function BS.reset()
    memo, st = {}, { qid = nil }
    bag.t, bag.count, bag.ids = -1e9, {}, {}
end

return BS
