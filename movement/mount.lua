-- ============================================================================
-- Master Farmer - Grindbot
-- movement/mount.lua - mount for travel (the 1-60 product's way)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.1
-- ============================================================================
-- Port of the 1-60 Grinding product's nav.lua mount_step (itself the AWM
-- Run() mount block), Core API only. Used by movement/nav before every
-- out-of-combat walk of MIN_WALK yd or more (questing, grinding and the
-- gathering patrol - gather/mount.lua is a thin wrapper).
--
-- WHICH MOUNT (looked up again every 10 s), in order:
--   1. a class mount spell the player knows (data/mounts: Summon Charger /
--      Warhorse for paladins, Summon Dreadsteed / Felsteed for warlocks)
--   2. a mount item in the bags: data/mounts item ids, or any item whose
--      item info (core.quests.get_item_info) is class 15 subclass 5 "Mount",
--      swift mounts first, min_level <= the player's level
--   3. the game's mount list (core.spell_book.get_mount_count /
--      get_mount_info(i).is_usable -> core.input.mount(i))
--   A druid shifts into Travel Form instead (never also mounts).
-- WHEN: not mounted, level >= MIN_LEVEL (or Travel Form known), not a ghost,
--   not in combat, not swimming, outdoors, not casting, the GUI box on, not
--   suppressed (gather: near a node), not backed off.
-- HOW: the walk is stopped and the player stands HOLD s for the cast (the
--   caller gives the tick up while step() is true). VERIFY s without a mount
--   counts a failed try; 5 tries -> no mounting for 15 s; no mount anywhere ->
--   walk, look again in a minute.
-- BACK-OFFS from the game's error messages (events.lua UI_ERROR_MESSAGE,
--   as the 1-60 product's events.lua): "can't mount" / "mount here" / "only
--   use outside" / "in combat" 25 s, "swimming" / "underwater" 60 s, "not
--   ready yet" 15 s, "while moving" 1.5 s.
-- Dismounting stays where it was: combat.dismount (40 yd from a target),
-- resting, gather at a node.
-- ============================================================================

local R = require("movement/core")

local M = {}

M.MIN_WALK = 30               -- yd: shorter walks are walked
M.MIN_LEVEL = 30
local HOLD = 5.0              -- s the player stands for a mount cast
local VERIFY = 3.0            -- s: no mount by then = a failed try
local CACHE_S = 10            -- s between two looks for a mount
local CLASS_WARLOCK, CLASS_DRUID = 9, 11

local okd, DATA = pcall(require, "data/mounts")
if not okd or type(DATA) ~= "table" then DATA = { class_spells = {}, items = {}, rank = {} } end

local st = { usable_at = 0, suppress_until = 0, tried_at = 0, tries = 0, hold_until = 0, pending_at = nil,
    logged = false, auto = nil, auto_t = -1e9, last_shift = 0 }
M.stats = { mounts = 0, shifts = 0, backoffs = 0 }

--- Set by movement.lua: function() -> the GUI "Use Mount" state for this mode.
M.enabled_fn = nil

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function spellbook() return package.loaded["spellbook"] or safe(require, "spellbook") end
local function spellcheck() return package.loaded["spellcheck"] or safe(require, "spellcheck") end

local function family(name)
    local sb = spellbook()
    if type(sb) ~= "table" or type(sb.family) ~= "function" then return nil end
    return safe(sb.family, name)
end

local function cast_self(fam, player, label)
    local sc = spellcheck()
    if not fam or not fam.id or type(sc) ~= "table" or type(sc.cast_safe) ~= "function" then return false end
    return safe(sc.cast_safe, fam.id, player, label) == true
end

--- Is one of the family's spell ids (Travel Form ranks) an aura on the player? (get_buffs)
local function has_aura(player, fam)
    local ids = {}
    for _, id in ipairs(fam.ranks or {}) do ids[id] = true end
    if fam.id then ids[fam.id] = true end
    local list = safe(player.get_buffs, player)
    if type(list) ~= "table" then return false end
    for _, b in ipairs(list) do
        if type(b) == "table" and (ids[b.buff_id] or b.buff_name == fam.name) then return true end
    end
    return false
end

--- Hold mounting off for `seconds` (gather: a node is close).
function M.suppress(seconds)
    local t = R.now() + (seconds or 10)
    if t > st.suppress_until then st.suppress_until = t end
end

--- No mounting for `seconds` (a game error message said why).
function M.backoff(seconds, why)
    local t = R.now() + (seconds or 15)
    if t > st.usable_at then st.usable_at = t end
    st.hold_until, st.pending_at = 0, nil
    M.stats.backoffs = M.stats.backoffs + 1
    if why then R.trail("move", "mount: %s - no mounting for %.0f s", tostring(why), seconds or 15) end
end

function M.reset()
    st.usable_at, st.suppress_until, st.tried_at, st.tries, st.hold_until, st.pending_at = 0, 0, 0, 0, 0, nil
    st.logged, st.auto, st.auto_t, st.last_shift = false, nil, -1e9, 0
end

--- The game's error text -> a back-off (events.lua UI_ERROR_MESSAGE).
function M.on_error(text)
    if type(text) ~= "string" or text == "" then return end
    local s = text:lower()
    local function has(x) return s:find(x, 1, true) ~= nil end
    if has("can't mount") or has("cannot mount") or has("mount here") or (has("too far away") and has("mount")) then
        M.backoff(25, text)
    elseif has("only use outside") or has("only be used outside") or has("can only use outside") then
        M.backoff(25, text)
    elseif has("you are in combat") then
        M.backoff(25, text)
    elseif has("while swimming") or has("underwater") or has("above water") then
        M.backoff(60, text)
    elseif has("not ready yet") then
        M.backoff(15, text)
    elseif has("while moving") and st.pending_at then
        M.backoff(1.5, text)
    end
end

-- ----------------------------------------------------------------------------
-- which mount
-- ----------------------------------------------------------------------------
local function bag_mount(level)
    local okb, bags = pcall(require, "bags")
    if not okb or type(bags) ~= "table" or type(bags.list) ~= "function" then return nil end
    local list = safe(bags.list) or {}
    local best, best_rank = nil, math.huge
    for _, it in ipairs(list) do
        local id = it.item_id
        if type(id) == "number" and id > 0 then
            local info = safe(core.quests.get_item_info, id)
            local listed = DATA.rank[id] ~= nil
            local is_mount = listed or (type(info) == "table" and info.class_id == 15 and info.subclass_id == 5)
            local min_level = type(info) == "table" and tonumber(info.min_level) or 0
            if is_mount and min_level <= level then
                local r = DATA.rank[id] or (#DATA.items + 1)
                if r < best_rank then
                    best, best_rank = { id = id, name = type(info) == "table" and info.name or nil }, r
                end
            end
        end
    end
    return best
end

local function journal_mount()
    local n = safe(core.spell_book.get_mount_count)
    if type(n) ~= "number" or n <= 0 then return nil end
    for i = 1, n do
        local info = safe(core.spell_book.get_mount_info, i)
        if type(info) == "table" and info.is_usable == true then return i, info.mount_name end
    end
    return nil
end

--- The mount to use: { kind = "spell"|"item"|"journal", value, label } or nil.
function M.find(player, t)
    t = t or R.now()
    if t - st.auto_t < CACHE_S then return st.auto end
    st.auto_t, st.auto = t, nil
    local class_id = safe(player.get_class, player)
    for _, name in ipairs(DATA.class_spells[class_id] or {}) do
        local fam = family(name)
        if fam and fam.id then
            st.auto = { kind = "spell", value = fam, label = name }
            return st.auto
        end
    end
    local level = safe(player.get_level, player) or 0
    local it = bag_mount(level)
    if it then
        st.auto = { kind = "item", value = it.id, label = it.name or ("item " .. it.id) }
        return st.auto
    end
    local idx, name = journal_mount()
    if idx then st.auto = { kind = "journal", value = idx, label = name or ("mount " .. idx) } end
    return st.auto
end

-- ----------------------------------------------------------------------------
-- the step before a walk
-- ----------------------------------------------------------------------------
local function enabled(explicit)
    if explicit ~= nil then return explicit == true end
    if type(M.enabled_fn) ~= "function" then return true end
    local ok, v = pcall(M.enabled_fn)
    return not ok or v ~= false
end

--- Mount (or shift) before travel. True while it holds the walk: the caller
--- gives the tick up (the player stands for the cast). `on` overrides the GUI
--- switch (gather passes its own box).
function M.step(player, on)
    if not player then return false end
    local t = R.now()
    if safe(player.is_mounted, player) == true then
        st.tries, st.pending_at, st.hold_until = 0, nil, 0
        return false
    end
    if st.pending_at then
        if t - st.pending_at < VERIFY then return true end
        st.pending_at = nil
        st.tries = st.tries + 1
        if st.tries > 5 then
            st.tries = 0
            M.backoff(15, "5 mount tries failed")
            return false
        end
    end
    if t < st.hold_until then return true end
    if not enabled(on) or t < st.usable_at or t < st.suppress_until then return false end

    local level = safe(player.get_level, player) or 0
    local class_id = safe(player.get_class, player)
    local travel = (class_id == CLASS_DRUID) and family("Travel Form") or nil
    if class_id == CLASS_WARLOCK and level <= 40 and not M.find(player, t) then
        st.usable_at = t + 120
        return false
    end
    if not travel and level < M.MIN_LEVEL then return false end
    if safe(player.is_ghost, player) == true then return false end
    if safe(player.is_in_combat, player) == true then return false end
    if safe(core.character.is_swimming) == true then return false end
    if safe(player.is_outdoors, player) == false then
        st.usable_at = t + 20                 -- the 1-60 rule: indoors, look again in 20 s
        return false
    end
    if safe(player.is_casting_spell, player) == true or safe(player.is_channelling_spell, player) == true then return true end

    -- Druid: Travel Form, never a mount.
    if travel then
        local fam = travel
        if has_aura(player, fam) or (t - st.last_shift) < 1 then return false end
        local nav = package.loaded["movement/nav"]
        if nav and type(nav.stop) == "function" then pcall(nav.stop, "travel form") end
        if cast_self(fam, player, "MF travel form") then
            st.last_shift = t
            M.stats.shifts = M.stats.shifts + 1
            R.trail("move", "mount: Travel Form")
        end
        return false
    end

    local m = M.find(player, t)
    if not m then
        if not st.logged then
            st.logged = true
            R.log("Mount: no mount found (class spell, bags or mount list) - walking")
        end
        st.usable_at = t + 60
        return false
    end
    st.logged = false
    -- a mount cast fails on the move: stop first, cast standing
    local nav = package.loaded["movement/nav"]
    if nav and type(nav.stop) == "function" then pcall(nav.stop, "mounting") end
    if safe(player.is_moving, player) == true then
        st.hold_until = t + 0.5
        return true
    end
    local sent
    if m.kind == "spell" then
        sent = cast_self(m.value, player, "MF mount")
    elseif m.kind == "item" then
        local sc = spellcheck()
        sent = type(sc) == "table" and type(sc.use_item) == "function" and safe(sc.use_item, m.value) == true
    else
        sent = safe(core.input.mount, m.value) ~= false
    end
    st.pending_at, st.hold_until, st.tried_at = t, t + HOLD, t
    M.stats.mounts = M.stats.mounts + 1
    R.trail("move", "mount: %s (%s)%s", tostring(m.label), m.kind, sent and "" or " - not sent")
    return true
end

--- Should a walk of `yards` mount first? (no state change)
function M.wants(yards) return type(yards) == "number" and yards >= M.MIN_WALK end

return M
