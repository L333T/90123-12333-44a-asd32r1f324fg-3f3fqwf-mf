-- ============================================================================
-- Master Farmer - Grindbot
-- Spellbook — delayed scan, then auto-rank by name to the highest known ID
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.185.0
-- Folder: Master_Farmer_Grindbot
-- Wait 5 seconds so the client and IZI finish loading, then scan.
-- Re-scan on a level-up or a trainer visit (60 s safety net). DEFS are rank-1 IDs; highest matching ID wins.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local spellbook = {}

local WAIT_SEC = 5.0
-- A full scan is a native call per spell in the book - several hundred at
-- level 60 - and it used to run every 2 seconds for the whole session. The
-- book only changes at a trainer or on a level-up, so a rescan now waits for
-- one of those (spellbook.request_rescan, or the player's level changing),
-- with RESCAN_GAP as the safety net.
local SCAN_GAP = 60.0
local rescan_wanted = false
local last_level = nil
local started_at = izi.now()
local last_scan = 0
local scanned = false
local id_known = {}
local spell_known = {}
local watched = {}
-- Best-rank proxies and their binder (see BEST KNOWN RANK below). Declared
-- here because run_scan, defined before that section, re-binds them.
local proxies = {}
local rebind
local book_count = 0
local book_ids = {}
local book_names = {}

-- Every spell the character has, grouped into rank families.
--
-- The scanner already read the whole book to answer the defined keys; it just
-- threw the rest away. Grouping it costs one pass and gives the GUI the thing
-- it actually wants: one row per spell, at the best rank, rather than eleven
-- rows of Frostbolt.
local families = {}        -- array of { id, name, ranks = { id, ... }, category }
local unnamed = {}         -- ids the client will not name and cannot group
local by_category = {}     -- category -> array of families
local families_by_name = {}
local defs = {}
local resolved_name = {}
local best_id = {}
local all_ranks = {}
local spells = {}
local generation = 0

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function spell_name(id)
    if type(id) ~= "number" or id <= 0 then
        return nil
    end
    local name = safe(function()
        return core.spell_book.get_spell_name(id)
    end)
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

local function mark_id(id)
    if type(id) == "number" and id > 0 then
        if not id_known[id] then
            id_known[id] = true
            book_count = book_count + 1
        end
    end
end

-- ============================================================================
-- COLLECT EVERY SPELL ID
-- ============================================================================
-- Recursive, and it takes numeric KEYS and numeric VALUES at every depth.
--
-- The previous version probed twelve entries, decided globally whether ids
-- lived in the keys or the values, and then only looked one level down. On the
-- three shapes core.spell_book.get_spells() can actually return that is not
-- enough - measured against a stub, a mixed table lost half the book and a
-- table nested by spell tab lost all of it. Whether the client groups by tab,
-- returns a flat list, or returns a set, this finds the same ids.
--
-- `visited` guards against a cyclic table, which a recursive walk would
-- otherwise follow for ever.
local function collect_ids(value, out, visited)
    if value == nil then
        return
    end

    local t = type(value)
    if t == "number" then
        if value > 0 and value == math.floor(value) then
            out[value] = true
        end
        return
    end
    if t ~= "table" then
        return
    end

    visited = visited or {}
    if visited[value] then
        return
    end
    visited[value] = true

    for k, v in pairs(value) do
        if type(k) == "number" and k > 0 and k == math.floor(k) then
            out[k] = true
        end
        collect_ids(v, out, visited)
    end
end

--- Does THIS character own the spell?
---
--- The recursive walk cannot tell a spell id from an array index - a flat list
--- of four spells has keys 1..4, and taking those produced four phantom
--- entries. Every candidate therefore has to be put to the client.
---
--- Ownership is the only question worth asking. core.spell_book.get_spell_name
--- answers for any id in the game's spell data, so a name proves the id exists,
--- not that this character learned it: index 78 named itself "Heroic Strike"
--- and 2457 "Battle Stance", so a Hunter's Spells tab offered Warrior
--- abilities, and smart.lua treated them as known because the family was in the
--- book. has_spell / is_spell_learned / is_spell_known are per-character, which
--- is what id_in_book below already relies on.
local function owns_spell(id)
    if type(id) ~= "number" or id <= 0 then
        return false
    end
    if safe(function() return core.spell_book.has_spell(id) end) == true then
        return true
    end
    if safe(function() return core.spell_book.is_spell_learned(id) end) == true then
        return true
    end
    return safe(function() return core.spell_book.is_spell_known(id) end) == true
end

local name_fallback_warned = false

--- Every id in the book this character owns, sorted.
local function extract_ids(raw)
    local set = {}
    collect_ids(raw, set, nil)

    local ids = {}
    for id in pairs(set) do
        if owns_spell(id) then
            ids[#ids + 1] = id
        end
    end

    -- A client that answers none of the three ownership calls would leave the
    -- book empty and the rotation with nothing to cast, so fall back to "the
    -- game can name it" - what every build before this one did - and say so
    -- once, because that is when a wrong-class spell can still appear.
    if #ids == 0 then
        for id in pairs(set) do
            if spell_name(id) then
                ids[#ids + 1] = id
            end
        end
        if #ids > 0 and not name_fallback_warned then
            name_fallback_warned = true
            core.log_warning(
                "[Master Farmer - Grindbot] Spellbook: this client confirms no spell ownership "
                .. "(has_spell / is_spell_learned / is_spell_known all answer false), so the book "
                .. "falls back to every id the game can name and the Spells tab may list abilities "
                .. "your class cannot use.")
        end
    end

    table.sort(ids)
    return ids
end

local function ingest_book(raw)
    book_ids = extract_ids(raw)
    book_names = {}
    book_count = 0
    id_known = {}
    for i = 1, #book_ids do
        local id = book_ids[i]
        mark_id(id)
        local name = spell_name(id)
        if name then
            book_names[id] = name
        end
    end
end

-- ============================================================================
-- Group The Whole Book Into Rank Families
-- ============================================================================
-- Ranks are grouped by base spell id, which is what the client itself uses to
-- say "these are the same spell" - Frostbolt rank 1 and rank 11 share one base
-- id. Name is the fallback for a build where get_base_spell_id is unhelpful,
-- and is also what keeps the grouping right for spells the API returns a base
-- id of 0 for.
--
-- The highest id in a family is taken as the best rank. That is the same
-- assumption rank_families already makes for defined keys, and it holds
-- because Blizzard issues ascending ids per rank within a spell.
--- Which category a family belongs to, via the registered rules.
--- Nothing is guessed from the fact that a spell exists: a family with no
--- matching rule lands in "other" and is still shown.
local function classify(fam)
    local ok, rules = pcall(require, "data/spell_categories")
    if not ok or type(rules) ~= "table" or type(rules.category_of) ~= "function" then
        return "other"
    end
    local cat = safe(function()
        return rules.category_of(fam.id, fam.name)
    end)
    if type(cat) == "string" and cat ~= "" then
        return cat
    end
    return "other"
end

local function group_families()
    families = {}
    families_by_name = {}
    by_category = {}

    local by_key = {}
    local order = {}

    unnamed = {}

    for i = 1, #book_ids do
        local id = book_ids[i]
        local base = safe(function()
            return core.spell_book.get_base_spell_id(id)
        end)
        local has_base = (type(base) == "number" and base > 0)

        -- The name, tried through the base spell too. A rank whose own id will
        -- not resolve usually shares a base id with one that will, and taking
        -- the base's name is what lets that rank join its family instead of
        -- standing alone.
        local name = book_names[id] or spell_name(id)
        if not name and has_base then
            name = book_names[base] or spell_name(base)
        end

        if not name and not has_base then
            -- Nothing to group it by and nothing to call it. Previously this
            -- was labelled "Spell <id>", which is unique per rank - so every
            -- rank of it became its own family and the list showed eleven
            -- Frostbolts instead of one. Count it and move on; the tab
            -- reports the total rather than a screen of numbered rows.
            unnamed[#unnamed + 1] = id
        else
            name = name or ("Spell " .. tostring(base))

            -- Key on the base id when the client gives a usable one, on the
            -- name otherwise. Two spells sharing a name but not a base id are
            -- the same family; two sharing neither are not.
            local key
            if has_base then
                key = "b" .. tostring(base)
            else
                key = "n" .. name
            end

            local fam = by_key[key]
            if not fam then
                fam = { id = id, name = name, ranks = {} }
                by_key[key] = fam
                order[#order + 1] = fam
            end
            fam.ranks[#fam.ranks + 1] = id
            if id > fam.id then
                fam.id = id
                fam.name = name
            end
        end
    end

    for i = 1, #order do
        local fam = order[i]
        table.sort(fam.ranks)
        fam.category = classify(fam)
        families[#families + 1] = fam
        families_by_name[fam.name] = fam
        local bucket = by_category[fam.category]
        if not bucket then
            bucket = {}
            by_category[fam.category] = bucket
        end
        bucket[#bucket + 1] = fam
    end

    table.sort(families, function(a, b)
        return a.name < b.name
    end)
    for _, list in pairs(by_category) do
        table.sort(list, function(a, b)
            return a.name < b.name
        end)
    end
end

local function id_in_book(id)
    if type(id) ~= "number" then
        return false
    end
    if id_known[id] then
        return true
    end
    if safe(function() return core.spell_book.has_spell(id) end) == true then
        mark_id(id)
        return true
    end
    if safe(function() return core.spell_book.is_spell_learned(id) end) == true then
        mark_id(id)
        return true
    end
    if safe(function() return core.spell_book.is_spell_known(id) end) == true then
        mark_id(id)
        return true
    end
    return false
end

local function evaluate_spell(spell)
    if type(spell) ~= "table" or not scanned then
        return false
    end
    -- A best-rank proxy is learned exactly when a rank of it is in the book.
    if rawget(spell, "_ids") ~= nil then
        local known = rawget(spell, "_best") ~= nil
        spell_known[spell] = known or nil
        return known
    end
    if spell_known[spell] == true then
        return true
    end
    if safe(function() return spell:is_learned() end) == true then
        spell_known[spell] = true
        return true
    end
    local ids = spell.ids
    if type(ids) == "table" then
        for i = 1, #ids do
            if id_in_book(ids[i]) then
                spell_known[spell] = true
                return true
            end
        end
    end
    local active = safe(function() return spell:id() end)
    if id_in_book(active) then
        spell_known[spell] = true
        return true
    end
    return false
end

local function rank_families()
    for key, seed in pairs(defs) do
        if not resolved_name[key] then
            local n = spell_name(seed)
            if n then
                resolved_name[key] = n
            end
        end
    end
    local changed = false
    for key, seed in pairs(defs) do
        local want = resolved_name[key]
        local ranks = {}
        local seen = {}
        local function consider(id)
            if type(id) ~= "number" or id <= 0 or seen[id] then
                return
            end
            if not id_in_book(id) then
                return
            end
            local name = book_names[id] or spell_name(id)
            local match = false
            if want and name == want then
                match = true
            else
                local base = safe(function()
                    return core.spell_book.get_base_spell_id(id)
                end)
                local seed_base = safe(function()
                    return core.spell_book.get_base_spell_id(seed)
                end)
                if type(base) == "number" and type(seed_base) == "number" and base > 0 and base == seed_base then
                    match = true
                elseif id == seed then
                    match = true
                end
            end
            if match then
                seen[id] = true
                ranks[#ranks + 1] = id
            end
        end
        for i = 1, #book_ids do
            consider(book_ids[i])
        end
        consider(seed)
        table.sort(ranks)
        all_ranks[key] = ranks
        local top = ranks[#ranks]
        if type(top) == "number" and best_id[key] ~= top then
            best_id[key] = top
            local spell = izi.spell(top)
            if spell then
                spells[key] = spell
            end
            changed = true
        end
    end
    if changed then
        generation = generation + 1
    end
end

local scan_count = 0

local function run_scan()
    ingest_book(safe(function()
        return core.spell_book.get_spells()
    end))
    group_families()
    scanned = true
    scan_count = scan_count + 1
    last_scan = izi.now()
    rank_families()
    spell_known = {}                  -- re-judged against the new ranks
    for i = 1, #proxies do
        rebind(proxies[i])
    end
    for i = 1, #watched do
        evaluate_spell(watched[i])
    end
end

function spellbook.define(map)
    if type(map) ~= "table" then
        return
    end
    for key, id in pairs(map) do
        if type(key) == "string" and type(id) == "number" and id > 0 then
            defs[key] = id
        end
    end
end

-- ----------------------------------------------------------------------------
-- BEST KNOWN RANK (2.52.0)
-- ----------------------------------------------------------------------------
-- Every rotation builds a spell from a rank list, highest first, and the
-- "is it learned" test answered yes when ANY rank was in the book - but the
-- cast went out as the spell object's own id, which was not necessarily a
-- rank the character had. At low level the rotation kept casting a rank it
-- had not learned: "spell not learned", over and over.
--
-- watch() now returns a thin proxy. Rotation code calls it exactly as before
-- (spell:cast_safe(...), spell:cooldown_up(), ...); the proxy forwards to an
-- izi spell bound to ONE id. After every scan - start-up, a level-up, a
-- trainer purchase - each proxy is re-bound to the highest rank of its list
-- that is actually in the spellbook, with its buff / debuff tracking re-applied
-- over the whole list, so an aura from any rank still counts. A spell with no
-- known rank stays unbound and reads as not learned, so it is never cast.
rebind = function(proxy)
    local ids = rawget(proxy, "_ids")
    if type(ids) ~= "table" then
        return
    end
    local best = nil
    for i = 1, #ids do               -- highest rank first
        if id_in_book(ids[i]) then
            best = ids[i]
            break
        end
    end
    rawset(proxy, "_best", best)
    if not best or rawget(proxy, "_bound") == best then
        return
    end
    local sp = safe(function() return izi.spell(best) end)
    if type(sp) ~= "table" then
        return
    end
    if rawget(proxy, "_buff") and type(sp.track_buff) == "function" then
        pcall(sp.track_buff, sp, ids)
    end
    if rawget(proxy, "_debuff") and type(sp.track_debuff) == "function" then
        pcall(sp.track_debuff, sp, ids)
    end
    rawset(proxy, "_cur", sp)
    rawset(proxy, "_bound", best)
    rawset(proxy, "_fn", {})
end

local proxy_mt = {
    __index = function(t, k)
        local cur = rawget(t, "_cur")
        local v = cur[k]
        if type(v) ~= "function" then
            return v
        end
        -- A method: call it on whatever the proxy is bound to NOW.
        local cache = rawget(t, "_fn")
        local f = cache[k]
        if not f then
            f = function(self, ...)
                local target = rawget(t, "_cur")
                local m = target[k]
                if self == t then
                    return m(target, ...)
                end
                return m(self, ...)
            end
            cache[k] = f
        end
        return f
    end,
}

--- Register a spell for the scan. `ids` is its rank list (highest first);
--- `track_buff` / `track_debuff` say whether the rotation tracks an aura
--- from it. Returns the proxy the rotation keeps.
function spellbook.watch(spell, ids, track_buff, track_debuff)
    if type(spell) ~= "table" then
        return spell
    end
    if type(ids) ~= "table" then
        watched[#watched + 1] = spell
        return spell
    end
    local proxy = setmetatable({
        _cur = spell, _ids = ids, _buff = track_buff == true, _debuff = track_debuff == true,
        _fn = {}, _bound = nil, _best = nil,
        ids = ids,
    }, proxy_mt)
    proxies[#proxies + 1] = proxy
    watched[#watched + 1] = proxy
    if scanned then
        rebind(proxy)
    end
    return proxy
end

--- The rank id a watched spell is cast as, or nil when no rank is known.
function spellbook.bound_id(proxy)
    return type(proxy) == "table" and rawget(proxy, "_best") or nil
end

function spellbook.ready()
    return scanned
end

function spellbook.wait_left()
    if scanned then
        return 0
    end
    local left = WAIT_SEC - (izi.now() - started_at)
    if left < 0 then
        return 0
    end
    return left
end

function spellbook.tick()
    local now = izi.now()
    if not scanned then
        if (now - started_at) < WAIT_SEC then
            return false
        end
        run_scan()
        core.log(string.format(
            "[Master Farmer - Grindbot] Spellbook scanned (%d entries, %d rotation spells watched).",
            book_count,
            #watched
        ))
        return true
    end
    local level = nil
    local okp, me = pcall(izi.me)
    if okp and me then
        local okl, l = pcall(me.get_level, me)
        if okl and type(l) == "number" then
            level = l
        end
    end
    if level and last_level and level ~= last_level then
        rescan_wanted = true
    end
    if level then
        last_level = level
    end
    if not rescan_wanted and (now - last_scan) < SCAN_GAP then
        return true
    end
    rescan_wanted = false
    run_scan()
    return true
end

--- Ask for a rescan on the next tick - after a spell was bought, say.
function spellbook.request_rescan()
    rescan_wanted = true
end

function spellbook.spell_known(spec)
    if not scanned then
        return false
    end
    if type(spec) == "string" then
        return type(best_id[spec]) == "number"
    end
    if type(spec) ~= "table" then
        return false
    end
    if spec.is_learned ~= nil or spec.ids ~= nil then
        return evaluate_spell(spec)
    end
    for i = 1, #spec do
        if evaluate_spell(spec[i]) then
            return true
        end
    end
    return false
end

function spellbook.has(key)
    return type(best_id[key]) == "number"
end

function spellbook.best_id(key)
    return best_id[key]
end

function spellbook.spell(key)
    return spells[key]
end

function spellbook.ranks(key)
    return all_ranks[key]
end

function spellbook.generation()
    return generation
end

--- How many scans have run. Moves on EVERY scan, so a cache built from the
--- families (the Spells tab / smart rotation, 2.64.0) knows to rebuild after a
--- trainer visit or a level-up even when no defined key changed rank.
function spellbook.scan_count()
    return scan_count
end

-- ============================================================================
-- The Whole Spellbook
-- ============================================================================
--- Every spell the character knows, one entry per rank family, sorted by name.
---
--- Each entry is { id = <best rank id>, name = <string>, ranks = { id, ... } }.
--- The table is rebuilt on every scan, so callers should read it rather than
--- hold it across frames; `generation` tells you when the resolved set moved.
function spellbook.all_families()
    return families
end

--- How many distinct spells the character has, as opposed to how many rank
--- rows the client reported.
function spellbook.family_count()
    return #families
end

--- One family by exact spell name, or nil.
function spellbook.family(name)
    if type(name) ~= "string" then
        return nil
    end
    return families_by_name[name]
end

--- Raw scan totals, for a status line: how many ids the client listed and how
--- many distinct spells that collapsed to.
function spellbook.counts()
    return book_count, #families
end

--- How many ids the scan found that the client would neither name nor give a
--- base spell for. They are real spells the character has, so they are counted
--- rather than dropped, but they cannot be shown as named rows.
function spellbook.unnamed_count()
    return #unnamed
end

--- The family NAME that owns this spell id, or nil.
---
--- Any rank answers with the family's name, so a checkbox registered against
--- rank 1 resolves to the same row the Spells tab draws at the top rank. That
--- is what lets a tick in the tab override a class checkbox.
function spellbook.name_of_id(id)
    if type(id) ~= "number" or id <= 0 then
        return nil
    end
    for i = 1, #families do
        local fam = families[i]
        if fam.id == id then
            return fam.name
        end
        local ranks = fam.ranks
        if type(ranks) == "table" then
            for r = 1, #ranks do
                if ranks[r] == id then
                    return fam.name
                end
            end
        end
    end
    return nil
end

--- Families of one category, sorted by name.
function spellbook.category(cat)
    return by_category[cat] or {}
end

--- Every category that actually has spells in it, in the registry's order.
function spellbook.categories()
    local ok, rules = pcall(require, "data/spell_categories")
    local order = (ok and type(rules) == "table" and rules.order) or { "other" }
    local out = {}
    for i = 1, #order do
        local cat = order[i]
        local list = by_category[cat]
        if list and #list > 0 then
            out[#out + 1] = { key = cat, label = (ok and rules.label and rules.label(cat)) or cat, spells = list }
        end
    end
    local leftovers = by_category["other"]
    local named = {}
    for i = 1, #order do
        named[order[i]] = true
    end
    if leftovers and #leftovers > 0 and not named["other"] then
        out[#out + 1] = { key = "other", label = "Other", spells = leftovers }
    end
    return out
end

return spellbook
