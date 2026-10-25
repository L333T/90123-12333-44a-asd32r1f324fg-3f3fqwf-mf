-- ============================================================================
-- restedXP_questing
-- quest/actions.lua - guide step actions the bot carries out itself
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.28.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.25.0 (user: "Always check the step action that should be completed and
-- complete that action. Use the Addon folder to get ALL of the needed itemid,
-- npc ID create table databases for every single step"). The survey of the
-- TBC / Classic guides found step actions with no handler - they fell to
-- "goto" (walk to the point and wait: the 'cast [goto]' and 'hs [goto]' steps
-- of the 2026-10-25 logs). data/rxp_steps.lua (tools/gen_rxp_steps.py) holds
-- every such step with its ids; the live goal's own ids come first.
--
--   cast / usespell  the spell (goal ids, else the step row's) - at the NPC the
--                    line names (".cast 8593 >> Use the Symbol of Life on Narm
--                    Faulk": walked to within CAST_YD), else at the current
--                    target / the player. A spell the character does not know
--                    is looked for as an ITEM's use spell in the bags
--                    (core.quests.get_item_spell) and that item is used on the
--                    unit. RestedXP ticks the step on UNIT_SPELLCAST_SUCCEEDED.
--   abandon          each named quest that is in the log (npc.abandon) - only
--                    what the guide line itself names
--   emote            ".emote salute,3401": at that NPC (walked to EMOTE_YD) -
--                    core.input.do_emote(token, unit)
--   tame             Hunters: Tame Beast (1515) on the named npc id; others skip
--   bankdeposit /    the API has no bank item call: the step is skipped (logged)
--   bankwithdraw
--   deathskip        never died for on purpose: the step is skipped (the route
--                    walks on)
-- A step whose action does not land after TRIES tries is skipped
-- (guide.skip_current, logged with why).
-- Public: A.KINDS, A.goal(player, goal, kind, wps, label, walk_to), A.row_for.
-- ============================================================================

local A = {}

A.KINDS = { cast = true, abandon = true, emote = true, tame = true, bank = true, deathskip = true }
A.CAST_YD, A.EMOTE_YD = 25, 8
A.GAP, A.TRIES = 3.0, 5
local TAME_BEAST = 1515
local HUNTER = 3

local st = { key = nil, t = -1e9, tries = 0, said = {} }
local rows = nil

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

local function trail(fmt, ...)
    local el = package.loaded["errorlog"]
    if type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "act", fmt, ...) end
end

local function mod(name)
    local m = package.loaded[name]
    if type(m) == "table" then return m end
    local ok, r = pcall(require, name)
    if ok and type(r) == "table" then return r end
    return nil
end

local function load_rows()
    if rows == nil then
        local ok, d = pcall(require, "data/rxp_steps")
        rows = (ok and type(d) == "table") and d or false
    end
    return rows or nil
end

local RAW = { cast = { cast = true, usespell = true }, abandon = { abandon = true }, emote = { emote = true },
    tame = { tame = true }, bank = { bankdeposit = true, bankwithdraw = true }, deathskip = { deathskip = true } }

--- The data/rxp_steps row + action for this goal: by the step's quest ids
--- (and the action), else by its waypoint (map + 0-1 point within 0.02).
function A.row_for(goal, kind, wps)
    local d = load_rows()
    if not d then return nil end
    local guide = mod("quest/guide")
    local qs = {}
    if type(goal.quest_id) == "number" then qs[goal.quest_id] = true end
    if guide and type(guide.goal_quest_ids) == "function" then
        for _, q in ipairs(safe(guide.goal_quest_ids, goal) or {}) do qs[q] = true end
    end
    local want = RAW[kind] or {}
    local function act_of(r)
        for i = 1, #(r.a or {}) do
            local t = r.a[i].t
            if want[t] or (kind == "cast" and t == "cast") or (kind == "bank" and t:find("^bank")) then return r.a[i] end
        end
        return nil
    end
    for i = 1, #d do
        local r = d[i]
        for j = 1, #(r.q or {}) do
            if qs[r.q[j]] then
                local a = act_of(r)
                if a then return r, a end
            end
        end
    end
    for k = 1, #(wps or {}) do
        local w = wps[k]
        local m, x, y = w and w.map_id, w and w.mx, w and w.my
        if type(m) == "number" and type(x) == "number" and type(y) == "number" then
            for i = 1, #d do
                local r = d[i]
                local p = r.p or {}
                for j = 1, #p - 2, 3 do
                    if p[j] == m and math.abs(p[j + 1] - x) <= 0.02 and math.abs(p[j + 2] - y) <= 0.02 then
                        local a = act_of(r)
                        if a then return r, a end
                    end
                end
            end
        end
    end
    return nil
end

local function skip(why, label)
    local guide = mod("quest/guide")
    if not st.said[label .. why] then
        st.said[label .. why] = true
        trail("step action '%s': %s - skipped", tostring(label), why)
    end
    if guide and type(guide.skip_current) == "function" then guide.skip_current(why) end
    return false
end

local function ids_for(goal, rec)
    local out = {}
    if type(goal.ids) == "table" then
        for i = 1, #goal.ids do if type(goal.ids[i]) == "number" and goal.ids[i] > 0 then out[#out + 1] = goal.ids[i] end end
    end
    if #out == 0 and rec and type(rec.ids) == "table" then
        for i = 1, #rec.ids do out[#out + 1] = rec.ids[i] end
    end
    return out
end

local function unit_named(player, name, range)
    if type(name) ~= "string" or name == "" then return nil end
    local tg = mod("targeting")
    if not tg or type(tg.find_named) ~= "function" then return nil end
    return safe(tg.find_named, player, name, nil, range or 60)
end

local function unit_id(player, id, range)
    local tg = mod("targeting")
    if not tg or type(tg.find_npc) ~= "function" then return nil end
    return safe(tg.find_npc, player, id, range or 60)
end

--- Walk to within `yd` of `unit`; true while walking.
local function close_to(player, unit, yd, label, walk_to)
    local d = tonumber(safe(function() return player:distance_to(unit) end)) or 99
    if d <= yd then return false end
    local p = safe(function() return unit:get_position() end)
    if p and type(walk_to) == "function" and walk_to(p, label, math.max(2, yd - 2), true) then
        local state = mod("state")
        if state then state.set_note("Quest", string.format("Guide: to %s (%.0f yd) - %s",
            tostring(safe(function() return unit:get_name() end)), d, tostring(label))) end
        return true
    end
    return false
end

--- The bag item whose use spell is `spell_id` (an item-spell cast), or nil.
local function item_with_spell(player, spell_id)
    local bags = mod("bags")
    local list = bags and type(bags.list) == "function" and safe(bags.list, player) or {}
    for i = 1, #list do
        local id = list[i].item_id
        if id then
            local sp = safe(function() return core.quests.get_item_spell(id) end)
            if type(sp) == "table" and tonumber(sp.spell_id) == spell_id then return id end
        end
    end
    return nil
end

local function stand(player)
    local movement = mod("movement")
    if movement then pcall(movement.nav_stop) end
    if safe(function() return player:is_mounted() end) == true then
        pcall(core.input.dismount)
        return true
    end
    return movement and movement.is_moving and movement.is_moving() == true or false
end

local function do_cast(player, goal, row, rec, label, walk_to)
    local ids = ids_for(goal, rec)
    if #ids == 0 then return skip("no spell id for the cast", label), false end
    local target = nil
    local name = rec and rec.to or (row and row.n and row.n[1]) or nil
    if name then
        target = unit_named(player, name, 60)
        if target and close_to(player, target, A.CAST_YD, label, walk_to) then return true, false end
    end
    if not target then
        local cur = safe(function() return player:get_target() end)
        if cur and safe(function() return cur:is_valid() end) == true then target = cur end
    end
    target = target or player
    if stand(player) then return true, false end
    local sc = mod("spellcheck")
    for i = 1, #ids do
        local id = ids[i]
        if sc and type(sc.core_castable) == "function" and sc.core_castable(id, target ~= player and target or nil) == true then
            local ok = sc.core_cast(id, target) == true
            trail("step action cast %d at %s for '%s': %s", id, tostring(safe(function() return target:get_name() end)),
                tostring(label), ok and "sent" or "refused")
            return true, true
        end
        local item = item_with_spell(player, id)
        if item then
            local ok
            if target ~= player then
                ok = safe(function() return core.input.use_item_target(item, target) end) == true
            else
                ok = sc and type(sc.use_item) == "function" and sc.use_item(item, { skip_moving = true }) == true
            end
            trail("step action: item %d (spell %d) used on %s for '%s': %s", item, id,
                tostring(safe(function() return target:get_name() end)), tostring(label), ok and "sent" or "refused")
            return true, true
        end
    end
    trail("step action cast for '%s': none of %s is castable yet", tostring(label), table.concat(ids, ", "))
    return true, true
end

--- One tick of a step action. True while the tick is spent here.
function A.goal(player, goal, kind, wps, label, walk_to)
    if not player or not A.KINDS[kind] then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    local t = now()
    local key = tostring(goal.index) .. "|" .. tostring(goal.text)
    if st.key ~= key then st.key, st.t, st.tries = key, -1e9, 0 end
    if safe(function() return player:is_channeling_or_casting() end) == true then return true end
    if (t - st.t) < A.GAP then return true end
    local row, rec = A.row_for(goal, kind, wps)
    if kind == "deathskip" then return skip("dying on purpose is never done", label) end
    if kind == "bank" then return skip("the API has no bank deposit / withdraw call - do it by hand", label) end
    if st.tries >= A.TRIES then return skip(string.format("did not land after %d tries", st.tries), label) end
    if kind == "abandon" then
        local npc = mod("quest/npc")
        local any = false
        for _, q in ipairs(ids_for(goal, rec)) do
            if safe(function() return core.quests.is_on_quest(q) end) == true and npc and type(npc.abandon) == "function" then
                npc.abandon(q)
                any = true
            end
        end
        st.t, st.tries = t, st.tries + 1
        if not any then
            local guide = mod("quest/guide")
            if guide and type(guide.mark_goal_done) == "function" then guide.mark_goal_done(guide.step_num(), goal.index) end
        end
        return true
    end
    if kind == "emote" then
        local id = rec and rec.ids and rec.ids[1] or nil
        local unit = id and unit_id(player, id, 60) or nil
        if unit and close_to(player, unit, A.EMOTE_YD, label, walk_to) then return true end      -- walking: not a try
        if stand(player) then return true end
        local token = rec and rec.token or string.upper(tostring(goal.text or "WAVE"):match("^(%a+)") or "WAVE")
        local ok = safe(function() return core.input.do_emote(token, unit) end) == true
        st.t, st.tries = t, st.tries + 1
        trail("step action emote %s at %s for '%s': %s", token, tostring(unit and safe(function() return unit:get_name() end)),
            tostring(label), ok and "done" or "refused")
        return true
    end
    if kind == "tame" then
        if tonumber(safe(function() return player:get_class() end)) ~= HUNTER then return skip("not a Hunter", label) end
        local id = ids_for(goal, rec)[1]
        local unit = id and unit_id(player, id, 80) or nil
        if not unit then return false end            -- walk the route until one shows
        if close_to(player, unit, A.CAST_YD, label, walk_to) then return true end
        if stand(player) then return true end
        local sc = mod("spellcheck")
        local ok = sc and type(sc.core_cast) == "function" and sc.core_cast(TAME_BEAST, unit) == true
        st.t, st.tries = t, st.tries + 1
        trail("step action Tame Beast on %s for '%s': %s", tostring(safe(function() return unit:get_name() end)),
            tostring(label), ok and "sent" or "refused")
        return true
    end
    -- cast / usespell
    local r, acted = do_cast(player, goal, row, rec, label, walk_to)
    if acted then st.t, st.tries = t, st.tries + 1 end
    return r
end

function A._reset() st = { key = nil, t = -1e9, tries = 0, said = {} } rows = nil end

return A
