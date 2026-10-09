-- ============================================================================
-- Master Farmer - Grindbot
-- Smart rotation - built from the spells ticked in the Spells tab
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.253.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHAT THIS IS (2.64.0)
--   The Spells tab lists every class spell the character knows, from
--   data/class_spells.lua filtered by the spellbook scan, plus the race's
--   castable racials. This file turns the ticked ones into the rotation, the
--   same for every class, driven by each spell's role:
--
--     combat, one action per call, highest first:
--       heal -> defensive -> interrupt (target, then any caster in the pack)
--       -> racials -> in-combat buffs (seal, shields, forms, stances)
--       -> resource -> opener -> execute -> control -> debuffs / DoTs
--       -> totems -> cooldowns -> AoE -> finishers -> damage -> filler
--
--     upkeep (in AND out of combat): every ticked buff, aura, armor, form,
--     stance, weapon imbue and - out of combat - the pet.
--
--   Within a role the class list's order is the priority. Spells that
--   cannot coexist share a group (one aura, one seal, one armor...) and only
--   the first ticked, known member of a group is used.
--
-- NON-BLOCKING
--   Nothing here waits. A call casts at most one spell and returns; the
--   caller's cascade (Rotation Only, grinding, questing) keeps its tick. A
--   spell that fails is set aside for FAIL_GAP so the next call falls
--   through to the next one instead of hammering it. Cast-time spells:
--     * Rotation Only - the player steers, so they are skipped while moving
--       and the bot never stops, turns or holds the character.
--     * Grinding / Questing - movement.prepare_cast holds the walker for the
--       cast, exactly as the mage rotation did.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local spellbook = require("spellbook")
local picks = require("picks")
local auras = require("auras")
local range = require("spell_range")
local state = require("state")
local catalog = require("data/class_spells")
local spellcheck = require("spellcheck")   -- 2.246.0: spell_helper gate on every cast
local why_not = {}          -- 2.251.0: spell name -> why try() passed it over (diagnostic)
-- READY TIMING (2.253.0): a spell waits - without the 1.5 s fail gap - for
-- its resource and the global cooldown, and fires on the first tick both
-- are there. The 03:33 Rogue log showed Sinister Strike tried every ~1.65 s
-- (FAIL_GAP 1.5 + a tick): energy-short attempts were refused and the spell
-- then sat out 1.5 s even after the energy was back.
local POWER_NAMES = { [0] = "mana", [1] = "rage", [3] = "energy", [6] = "runic power" }
local GCD_LATENCY = 0.30     -- s after a GCD cast before the next GCD spell is tried
local last_gcd_cast = -1e9
-- 2.252.0: pcall that keeps both return values (izi's ok, reason)
local function safe2(fn)
    local ok, a, b = pcall(fn)
    if ok then return a, b end
    return nil, tostring(a)
end
local racial_data = require("data/racials")

local smart = {}

local FAIL_GAP = 1.5          -- seconds a failed spell is skipped
local BUFF_FAIL_GAP = 8.0     -- a buff that failed (no reagent, no rage...) waits longer
local UPKEEP_GAP = 1.0        -- seconds between two buff casts
local SEAL_REACH = 8
local SEAL_LATCH = 3.0

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then
        return r
    end
    return nil
end

-- Lazy modules: each of these requires something that sits above this file in
-- the load order, or is not needed until the first fight.
local mods = {}
local function mod(name)
    local m = mods[name]
    if m then return m end
    local ok, r = pcall(require, name)
    if ok and type(r) == "table" then
        mods[name] = r
        return r
    end
    return nil
end


-- Flight-recorder probe (2.68.0). Free unless the Crash Recorder box is ticked:
-- then each one is a disk line, and the last line before a crash names the
-- native call the game died in.
local probe_el = nil
local function xprobe(tag)
    if probe_el == nil then
        local ok, m = pcall(require, "errorlog")
        probe_el = (ok and type(m) == "table" and type(m.probe) == "function") and m or false
    end
    if probe_el then
        pcall(probe_el.probe, tag)
    end
end

local function mark_dirty()
    local s = mod("settings")
    if s and type(s.mark_dirty) == "function" then
        pcall(s.mark_dirty)
    end
end

-- ============================================================================
-- SETTINGS (Spells tab sliders)
-- ============================================================================
local function slider(key, fallback)
    local gui = mod("gui")
    if gui and type(gui.slider) == "function" then
        local v = gui.slider(key, fallback)
        if type(v) == "number" then
            return v
        end
    end
    return fallback
end

local function rotation_only()
    local gui = mod("gui")
    return gui ~= nil and type(gui.is_on) == "function" and gui.is_on("rotation_only") == true
end

-- ============================================================================
-- THE LIST - catalog entries this character knows, rebuilt after each scan
-- ============================================================================
local SELF_ROLES = {
    buff = true, cbuff = true, form = true, seal = true, imbue = true, pet = true,
    petheal = true, heal = true, defensive = true, resource = true, cooldown = true,
    totem = true, control = true,
}

-- Channelled spells hold the walker for the whole channel.
local CHANNEL = {
    ["Mind Flay"] = true, ["Drain Life"] = true, ["Drain Soul"] = true,
    ["Arcane Missiles"] = true, ["Evocation"] = true, ["Health Funnel"] = true,
    ["Blizzard"] = true, ["Rain of Fire"] = true, ["Hurricane"] = true,
    ["Starshards"] = true,
}

-- Forms and stances, for "which one am I in" and for the spells that need one.
local FORM_OF = {
    ["Cat Form"] = "cat", ["Bear Form"] = "bear", ["Dire Bear Form"] = "bear",
    ["Moonkin Form"] = "moonkin", ["Tree of Life"] = "tree",
    ["Travel Form"] = "travel", ["Aquatic Form"] = "travel",
    ["Flight Form"] = "travel", ["Swift Flight Form"] = "travel",
}
local STANCE_BY_INDEX = { "battle", "defensive", "berserker" }
local STANCE_OF = { ["Battle Stance"] = "battle", ["Defensive Stance"] = "defensive", ["Berserker Stance"] = "berserker" }

local built = { scan = -1, class = nil, race = nil, list = {}, by_role = {}, rows = {}, groups = {} }
local spell_cache = {}         -- best-rank id -> izi spell

-- "Other known spells" (2.194.0): never listed, they are not abilities to tick.
-- PET UTILITY (2.225.0): a ticked "other" spell is cast on cooldown in every
-- fight (racials.lua), so Feed Pet went off every second at the hunter's
-- target. Pet care is pets.lua's job; these are never fight spells.
local OTHER_SKIP = { ["Attack"] = true, ["Auto Shot"] = true, ["Shoot"] = true,
    ["Feed Pet"] = true, ["Dismiss Pet"] = true, ["Tame Beast"] = true, ["Beast Training"] = true,
    ["Call Pet"] = true, ["Revive Pet"] = true, ["Mend Pet"] = true,
    -- UTILITY (2.240.0): a ticked one went off in every fight - Conjure Mana
    -- Agate 106 times in one session, ahead of Frostbolt. Blink or a Teleport
    -- ticked here would have fired mid-fight, Polymorph on the target itself.
    ["Blink"] = true, ["Slow Fall"] = true, ["Polymorph"] = true, ["Amplify Magic"] = true,
    ["Dampen Magic"] = true, ["Remove Lesser Curse"] = true, ["Remove Curse"] = true,
    ["Arcane Brilliance"] = true, ["Arcane Intellect"] = true, ["Evocation"] = true,
    ["Hearthstone"] = true, ["Unstuck"] = true }
-- ...and every spell whose name starts with one of these (item makers,
-- travel, gathering trackers, rituals).
local OTHER_SKIP_PREFIX = { "Conjure ", "Teleport", "Portal", "Create ", "Find ", "Ritual of ", "Track " }
local function other_skipped(name)
    if type(name) ~= "string" then return true end
    if OTHER_SKIP[name] then return true end
    for i = 1, #OTHER_SKIP_PREFIX do
        local p = OTHER_SKIP_PREFIX[i]
        if name:sub(1, #p) == p then return true end
    end
    return false
end
smart.NEVER_CAST_OTHER = OTHER_SKIP
smart.other_skipped = other_skipped

--- A passive spell (SPELL_ATTR0_PASSIVE, attribute 0 flag 0x40). A client
--- that does not answer leaves it listed.
local function is_passive(id)
    return safe(function() return core.spell_book.spell_has_attribute(id, 0, 0x40) end) == true
end

-- CASTABLE ONLY (2.196.0). WoW Forever does not answer the passive attribute,
-- and the list showed Armor Proficiency, Dodge, Engineering Specialization,
-- Expansive Mind and Languages - passives. An "other" spell is listed only
-- once core.spell_book.is_usable_spell has said true for one of its ranks
-- (a passive never is; an active one is whenever it could be cast). Sticky
-- for the session, so a spell short of mana at one scan does not drop out.
local seen_usable = {}

local function castable(fam, ranks)
    if seen_usable[fam.name] then return true end
    for k = #ranks, 1, -1 do
        local id = ranks[k]
        if safe(function() return core.spell_book.is_usable_spell(id) end) == true then
            seen_usable[fam.name] = true
            return true
        end
    end
    return false
end

-- One line per change of what the scan found (2.194.0), so a log says which
-- spells the Spells tab has - there was no way to tell a missing spell from a
-- spell the scan never saw.
local book_report = nil

local function report_book(cls, n_class, rows, other_names)
    local racial_names = {}
    for i = 1, #rows do
        if rows[i].role == "racial" then racial_names[#racial_names + 1] = rows[i].name end
    end
    local book_n, fam_n = 0, 0
    if type(spellbook.counts) == "function" then book_n, fam_n = spellbook.counts() end
    local text = string.format("Spells tab: %d class spell(s); racials: %s; other known spells (%d): %s",
        n_class, #racial_names > 0 and table.concat(racial_names, ", ") or "none",
        #other_names, #other_names > 0 and table.concat(other_names, ", ") or "none")
    if text == book_report then return end
    book_report = text
    core.log(string.format("[Master Farmer - Grindbot] %s (book: %d ids, %d spells, class %s).",
        text, book_n or 0, fam_n or 0, tostring(cls)))
    local el = mod("errorlog")
    if el and type(el.trail) == "function" then
        pcall(el.trail, "spells", "%s (book %d ids, %d spells)", text, book_n or 0, fam_n or 0)
    end
end

local function player_class(player)
    return safe(player.get_class, player)
end

local function build(player)
    if not player or not spellbook.ready() then
        return built
    end
    local cls = player_class(player)
    local race = safe(player.get_race_id, player)
    local scan = type(spellbook.scan_count) == "function" and spellbook.scan_count() or 0
    if built.scan == scan and built.class == cls and built.race == race then
        return built
    end

    local list, by_role, rows, groups = {}, {}, {}, {}
    local row_of = {}
    local defs = catalog.for_class(cls)

    -- Which catalog the character's class id resolved to. Worth a line, because
    -- get_class() reporting the wrong number is indistinguishable from a short
    -- Spells tab otherwise, and a wrong catalog is what puts another class's
    -- abilities on the page.
    if built.class ~= cls then
        core.log(string.format(
            "[Master Farmer - Grindbot] Class %s -> %s spell catalog (%d entries).",
            tostring(cls), tostring(catalog.class_key(cls) or "none"), #defs))
    end
    for i = 1, #defs do
        local def = defs[i]
        local name, role = def[1], def[2]
        local fam = spellbook.family(name)
        -- HARD-CODED ID (2.229.0): a catalog `id = <spell id>` is used when the
        -- scan has no family by that name but the character knows the id
        -- (Eviscerate 2098 for the rogue).
        if not fam and type(def.id) == "number" then
            local known = safe(function() return core.spell_book.is_spell_learned(def.id) end) == true
                or safe(function() return core.spell_book.has_spell(def.id) end) == true
            if known then fam = { id = def.id, ranks = { def.id }, name = name } end
        end
        if fam then
            local ids = (type(fam.ranks) == "table" and #fam.ranks > 0) and fam.ranks or { fam.id }
            local e = {
                def = def, name = name, role = role, id = fam.id, ids = ids,
                self = def.self == true or (SELF_ROLES[role] == true and def.enemy ~= true),
                key = name .. "|" .. role,
            }
            list[#list + 1] = e
            local bucket = by_role[role]
            if not bucket then
                bucket = {}
                by_role[role] = bucket
            end
            bucket[#bucket + 1] = e
            if def.g then
                local g = groups[def.g]
                if not g then
                    g = {}
                    groups[def.g] = g
                end
                g[#g + 1] = e
            end
            if not row_of[name] then
                local row = {
                    name = name, role = role, ranks = #ids, id = fam.id, group = def.g,
                    default = def.on ~= false, tip = def.tip,
                    section = catalog.section_of(role),
                }
                row_of[name] = row
                rows[#rows + 1] = row
            end
        end
    end

    -- Racials this race can actually cast.
    local rdefs = racial_data.for_race(race)
    for i = 1, #rdefs do
        local d = rdefs[i]
        local known = false
        for k = 1, #d.ids do
            if spellbook.name_of_id(d.ids[k]) then
                known = true
                break
            end
        end
        if known and not row_of[d.label] then
            local row = { name = d.label, role = "racial", ranks = 1, group = nil,
                default = d.default ~= false, tip = d.tooltip, section = "racial" }
            row_of[d.label] = row
            rows[#rows + 1] = row
        end
    end

    -- EVERY OTHER KNOWN SPELL (2.194.0). The tab showed only this class's
    -- catalog and the listed racials, so a spell the scan found but nobody
    -- catalogued (a WoW Forever racial, say) never appeared. Every remaining
    -- family in the book is listed here, unticked; ticked, racials.lua uses
    -- it on cooldown in a fight. Passive spells, spells the game never
    -- reported usable (2.196.0) and auto attacks are left out.
    local racial_ids = {}
    for i = 1, #(racial_data.list or {}) do
        local ids = racial_data.list[i].ids or {}
        for k = 1, #ids do racial_ids[ids[k]] = true end
    end
    local extra, other_names = {}, {}
    local fams = (type(spellbook.all_families) == "function" and spellbook.all_families()) or {}
    for i = 1, #fams do
        local fam = fams[i]
        local ranks = (type(fam.ranks) == "table" and #fam.ranks > 0) and fam.ranks or { fam.id }
        local is_racial = false
        for k = 1, #ranks do
            if racial_ids[ranks[k]] then is_racial = true break end
        end
        if not is_racial and not row_of[fam.name] and not other_skipped(fam.name) and not is_passive(fam.id)
            and castable(fam, ranks) then
            local desc = safe(function() return core.spell_book.get_spell_description(fam.id) end)
            local tip = (type(desc) == "string" and desc ~= "") and desc
                or "Found in your spell book; not in the class catalog."
            -- DPS OR HEALING (2.242.0), from the spell's own description: a
            -- spell that deals damage is a DPS spell cast at the target, one
            -- that only heals is cast on the player below the heal line. It is
            -- never taken for an AoE spell. Unticked by default either way.
            local use = smart.spell_use(desc)
            local section = (use == "heal" and "other_heal") or (use == "dps" and "other_dps") or "other"
            local row = { name = fam.name, role = section, ranks = #ranks, id = fam.id, group = nil,
                default = false, tip = tip, section = section }
            row_of[fam.name] = row
            rows[#rows + 1] = row
            extra[#extra + 1] = { key = "other:" .. fam.name, label = fam.name,
                kind = use == "heal" and "heal" or "offensive",
                default = false, extra = true, ids = ranks, tooltip = tip }
            other_names[#other_names + 1] = fam.name
        end
    end
    local rmod = mod("racials")
    if rmod and type(rmod.set_extra) == "function" then
        rmod.set_extra(extra)
    end
    report_book(cls, #list, rows, other_names)

    built = { scan = scan, class = cls, race = race, list = list, by_role = by_role,
        rows = rows, groups = groups }
    spell_cache = {}
    return built
end

local function spell_of(e)
    local sp = spell_cache[e.id]
    if sp == nil then
        sp = safe(izi.spell, e.id) or false
        spell_cache[e.id] = sp
    end
    return sp or nil
end

-- ============================================================================
-- ENABLED / GROUPS
-- ============================================================================
--- Ticked in the Spells tab? An untouched spell uses its catalog default.
function smart.is_enabled(name, default)
    local st = picks.state(name)
    if type(st) == "boolean" then
        return st
    end
    return default ~= false
end

local function enabled(e)
    return smart.is_enabled(e.name, e.def.on)
end

--- The member of a group in use: the first ticked one this character knows.
local function chosen(g)
    local members = built.groups[g]
    if not members then
        return nil
    end
    for i = 1, #members do
        if enabled(members[i]) then
            return members[i]
        end
    end
    return nil
end

local function usable(e)
    if not enabled(e) then
        return false
    end
    if e.def.g and chosen(e.def.g) ~= e then
        return false
    end
    return true
end

-- ============================================================================
-- CONTEXT - one reusable table, reset every call (no per-tick closures)
-- ============================================================================
local P, T, PACK = nil, nil, nil
local memo = {}

local function pct(v)
    if type(v) ~= "number" then return nil end
    if v >= 0 and v <= 1.5 then return v * 100 end
    return v
end

local function health_of(u)
    if not u then return 100 end
    local v = pct(safe(u.health_pct, u)) or pct(safe(u.get_health_percentage, u))
    if v then return v end
    local cur, mx = safe(u.get_health, u), safe(u.get_max_health, u)
    if type(cur) == "number" and type(mx) == "number" and mx > 0 then
        return cur / mx * 100
    end
    return 100
end

local c = {}

function c.hp()
    if memo.hp == nil then memo.hp = health_of(P) end
    return memo.hp
end

function c.thp()
    if memo.thp == nil then memo.thp = T and health_of(T) or 100 end
    return memo.thp
end

function c.mana()
    if memo.mana == nil then
        -- power.lua (2.202.0): izi first, native get_power (mana 0) as fallback.
        local pw = mod("power")
        local v = pw and pw.mana_pct(P) or pct(safe(P.mana_pct, P)) or 100
        memo.mana = v
    end
    return memo.mana
end

function c.rage()
    if memo.rage == nil then
        local r = safe(P.rage_current, P)
        if type(r) ~= "number" then
            local pt = enums.power_type and enums.power_type.RAGE
            r = type(pt) == "number" and safe(P.power_current, P, pt) or nil
        end
        memo.rage = type(r) == "number" and r or 0
    end
    return memo.rage
end

function c.cp()
    if memo.cp == nil then
        local n = safe(P.combo_points_current, P)
        if type(n) ~= "number" then n = safe(P.get_combo_points_target, P) end
        memo.cp = type(n) == "number" and n or 0
    end
    return memo.cp
end

function c.dist()
    if memo.dist == nil then
        memo.dist = T and (safe(P.distance_to, P, T) or 99) or 99
    end
    return memo.dist
end

function c.in_combat()
    if memo.combat == nil then memo.combat = safe(P.is_in_combat, P) == true end
    return memo.combat
end

function c.moving()
    if memo.moving == nil then memo.moving = safe(P.is_moving, P) == true end
    return memo.moving
end

--- Enemies in the pack within `r` yards of the player.
function c.near(r)
    local key = "n" .. r
    local v = memo[key]
    if v ~= nil then return v end
    local n = 0
    if type(PACK) == "table" then
        for i = 1, #PACK do
            local d = safe(P.distance_to, P, PACK[i])
            if type(d) == "number" and d <= r then n = n + 1 end
        end
    end
    memo[key] = n
    return n
end

--- Enemies in the pack within `r` yards of the target (the target counts).
function c.near_target(r)
    local key = "t" .. r
    local v = memo[key]
    if v ~= nil then return v end
    local n = 0
    if T and type(PACK) == "table" then
        for i = 1, #PACK do
            local u = PACK[i]
            local d = safe(T.distance_to, T, u)
            if type(d) == "number" and d <= r then n = n + 1 end
        end
    end
    if n == 0 and T then n = 1 end
    memo[key] = n
    return n
end

local function ranks_of(name)
    local fam = spellbook.family(name)
    if not fam then
        -- A hard-coded catalog id (2.229.0) stands in for a missing family.
        local list = built.list
        for i = 1, #list do
            if list[i].name == name then return list[i].ids end
        end
        return nil
    end
    return (type(fam.ranks) == "table" and #fam.ranks > 0) and fam.ranks or { fam.id }
end

--- Is the named buff (any rank) on the player?
function c.buff(name)
    local ids = ranks_of(name)
    return ids ~= nil and auras.buff_up(P, ids) == true
end

--- Stealthed (2.227.0)? izi stealth_up first, then the Stealth / Prowl buff.
function c.stealthed()
    if memo.stealth == nil then
        local v = safe(P.stealth_up, P)
        if type(v) ~= "boolean" then v = c.buff("Stealth") or c.buff("Prowl") end
        memo.stealth = v == true
    end
    return memo.stealth
end

--- In the target's rear arc (2.227.0)? izi is_behind_unit; unreadable = no.
function c.behind()
    if memo.behind == nil then
        local v = T and safe(P.is_behind_unit, P, T) or nil
        if type(v) ~= "boolean" and T then v = safe(P.is_behind, P, T) end
        memo.behind = v == true
    end
    return memo.behind
end

--- Is the named debuff (any rank) on the target?
function c.debuff(name)
    local ids = ranks_of(name)
    return T ~= nil and ids ~= nil and auras.debuff_up(T, ids) == true
end

function c.tdebuff_any(ids)
    return T ~= nil and auras.debuff_up(T, ids) == true
end

function c.self_debuff_id(id)
    return auras.debuff_up(P, { id }) == true
end

--- Is the target of this creature type ("UNDEAD", "DEMON", ...)?
function c.ttype(name)
    if not T then return false end
    local want = enums.creature_type and enums.creature_type[name]
    if type(want) ~= "number" then return false end
    return safe(T.get_creature_type, T) == want
end

--- Is any spell of group `g` up on the player (a seal, an aura...)?
function c.group_up(g)
    local members = built.groups[g]
    if not members then return false end
    for i = 1, #members do
        if auras.buff_up(P, members[i].ids) == true then
            return true
        end
    end
    return false
end

function c.heal_pct() return slider("sp_heal", 50) end
function c.def_pct() return slider("sp_def", 35) end
function c.aoe_n() return slider("sp_aoe", 3) end
function c.wand_pct() return slider("sp_wand", 20) end
function c.melee_yards()
    local m = slider("melee_yards", 5)
    if m < 1 then m = 1 elseif m > 5 then m = 5 end
    return m
end

--- The druid form / warrior stance the player is in ("caster" when none).
function c.form()
    if memo.form ~= nil then return memo.form end
    local f = nil
    if built.class == enums.class_id.WARRIOR then
        local idx = safe(core.spell_book.get_shapeshift_form_id)
        if type(idx) == "number" and STANCE_BY_INDEX[idx] then
            f = STANCE_BY_INDEX[idx]
        else
            for name, st in pairs(STANCE_OF) do
                if c.buff(name) then f = st break end
            end
        end
    else
        for name, form in pairs(FORM_OF) do
            local ids = ranks_of(name)
            if ids and auras.buff_up(P, ids) == true then
                f = form
                break
            end
        end
        f = f or "caster"
    end
    memo.form = f or false
    return memo.form
end

local function begin(player, target, pack)
    P, T, PACK = player, target, pack
    for k in pairs(memo) do memo[k] = nil end
end

-- ============================================================================
-- CASTING
-- ============================================================================
local fail_until = {}          -- entry key -> time
local last_cast = {}           -- entry key -> time
local last_upkeep = -1e9
local seal_cast_at = -1e9
-- The wand is auto-repeat: casting Shoot again while it is firing stops it.
-- So it is started once per target and left alone; any other cast (which
-- stops the wand anyway) clears the latch.
local wand_guid = nil
local shot_guid = nil

local function form_ok(def)
    local need = def.form
    if need == nil then return true end
    local f = c.form()
    if not f then return false end          -- unreadable stance: do not offer
    if type(need) == "string" then return f == need end
    for i = 1, #need do
        if need[i] == f then return true end
    end
    return false
end

local function ctype_ok(def)
    local list = def.ctype
    if not list then return true end
    for i = 1, #list do
        if c.ttype(list[i]) then return true end
    end
    return false
end

local function cast_seconds(sp)
    local ms = safe(sp.cast_time_ms, sp)
    if type(ms) == "number" and ms > 0 then return ms / 1000 end
    local ct = safe(sp.cast_time, sp)
    if type(ct) == "number" and ct > 0 then
        return ct > 20 and ct / 1000 or ct
    end
    return 0
end

local function note(label)
    local rot = mod("rotation")
    if rot and type(rot.set_last_action) == "function" then
        rot.set_last_action(label)
    end
    state.last_action = label
    if type(state.report_action) == "function" then
        state.report_action(label)
    end
end

--- SPELL QUEUE CASTING (2.249.0, castq.lua). On unless "Spell Queue Casting"
--- (Spells tab) is unticked, and only when common/modules/spell_queue loads.
local function queue_on()
    local g = mod("gui")
    if g and type(g.is_on) == "function" and g.is_on("spell_queue") == false then return nil end
    local cq = mod("castq")
    if cq and type(cq.available) == "function" and cq.available() then return cq end
    return nil
end

--- Queue entry `e` (priority 1) after the castability check: spell_helper
--- (spellcheck) normally; izi's own check with skip_casting while the current
--- cast is still finishing (queue ahead). Returns ok, soft - soft = not a
--- failure (already queued, or the off-GCD queue is busy this frame).
local function queue_cast(cq, e, sp, unit, pos)
    -- 2.250.0: izi's FULL castable check gates every queued spell (range,
    -- facing, resource, cooldown, line of sight) - the queue path skips
    -- cast_safe, so this is its only gate. spell_helper only advises.
    local ahead = safe(P.is_casting, P) == true
    -- 2.251.0: ALLOW MOVEMENT for instants and spells usable on the move.
    -- 2.249.0 queued everything with movement blocked: the queue then held
    -- a melee Rogue's strikes for as long as it kept stepping after its
    -- target - it cast nothing. Cast-time spells still wait (prepare_cast
    -- has already stopped the walk for them).
    local ct = tonumber(safe(function() return cast_seconds(sp) end)) or 0
    local allow_move = ct <= 0 or safe(sp.is_usable_while_moving, sp) == true
    local opts = { skip_facing = e.self == true, skip_moving = allow_move }
    if ahead then
        opts.skip_casting, opts.skip_gcd, opts.skip_moving = true, true, true
    end
    local okc, reason
    if pos then
        okc, reason = safe2(function() return sp:is_castable_to_position(unit, pos, opts) end)
    else
        okc, reason = safe2(function() return sp:is_castable_to_unit(unit, opts) end)
    end
    if okc ~= true then
        why_not[e.name .. "#izi"] = "izi: " .. tostring(reason or "not castable")
        if ahead then return false, true end
        return false, false, "izi"
    end
    if not ahead then
        local okg
        if pos then
            okg = spellcheck.can_cast_at(sp, P, unit, pos)
        else
            okg = spellcheck.can_cast(sp, P, unit, { self = e.self == true or unit == P })
        end
        if not okg then return false, false end
    end
    local ok, why = cq.cast(e.id, sp, unit, pos, e.name, allow_move)
    if ok then
        spellcheck.cast_done(sp)
        return true, false
    end
    if why == "requeue_gap" then return true, true end
    return false, why == "fast_queue_busy"
end

--- Cast entry `e` at `unit` (or at `pos` for a ground spell). One attempt,
--- no waiting. Returns true when the cast went out.
local function cast(e, unit, pos)
    -- Auto Shot is a toggle via auto_attack_helper (id 75), not a cast.
    -- cast_safe fails and FAIL_GAP then silences the hunter rotation.
    if e.name == "Auto Shot" and unit and not pos then
        local aa = require("common/utility/auto_attack_helper")
        local types = aa and aa.ATTACK_TYPE
        if type(types) == "table" and type(types.RANGED) == "number" then
            local ok_s = safe(function() return aa:start_attack(unit, types.RANGED) end)
            if ok_s == true then
                shot_guid = safe(unit.get_guid, unit)
                last_cast[e.key] = izi.now()
                note(e.name)
                return true
            end
        end
    end
    local sp = spell_of(e)
    if not sp then return false end
    if safe(sp.cooldown_up, sp) == false then return false end

    local hands_off = rotation_only()
    local ct = CHANNEL[e.name] and 3.0 or cast_seconds(sp)
    local locked = false
    -- Backpedalling (2.97.0): only what can be cast on the move, and no cast
    -- lock that would fight the backward walk.
    local mv_bp = mod("movement")
    if mv_bp and type(mv_bp.backpedaling) == "function" and mv_bp.backpedaling() then
        if ct > 0 and safe(sp.is_usable_while_moving, sp) ~= true then return false end
        hands_off = true
    end
    if ct > 0 and safe(sp.is_usable_while_moving, sp) ~= true then
        if hands_off then
            -- The player is steering: never stop them to cast.
            if c.moving() then return false end
        else
            local mv = mod("movement")
            if mv then
                if pos and type(mv.prepare_ground) == "function" then
                    mv.prepare_ground(pos, ct + 0.2, CHANNEL[e.name] == true)
                    locked = true
                elseif CHANNEL[e.name] and type(mv.prepare_channel) == "function" then
                    mv.prepare_channel(unit, ct + 0.2)
                    locked = true
                elseif type(mv.prepare_cast) == "function" then
                    mv.prepare_cast(unit, ct + 0.2)
                    locked = true
                end
            end
        end
    end

    local ok
    xprobe("sm:cast " .. e.name)
    local cq = queue_on()
    local direct = cq == nil
    if cq then
        local soft, qwhy
        ok, soft, qwhy = queue_cast(cq, e, sp, unit, pos)
        if ok ~= true and soft then
            xprobe("sm:cast done")
            if locked then
                local mv = mod("movement")
                if mv and type(mv.release) == "function" then pcall(mv.release) end
            end
            return false
        end
        -- 2.252.0: izi's castable check refused the queued cast. The Rogue's
        -- Sinister Strike was refused that way at 0.1 yd with 105 energy
        -- (03:29 log) while the direct casts below worked on 2.240 - try them.
        if ok ~= true and qwhy == "izi" then direct = true end
    end
    if direct then
        if pos then
            ok = safe(function() return spellcheck.cast_position(sp, pos, e.name, { min_hits = 1, aoe_radius = 8 }) end)
        else
            ok = safe(function() return spellcheck.cast_safe(sp, unit, e.name) end)
            if ok ~= true then
                ok = safe(function() return spellcheck.cast(sp, unit, e.name) end)
            end
        end
        if ok ~= true then why_not[e.name] = "cast refused (" .. tostring(why_not[e.name .. "#izi"] or "izi cast") .. ")" end
    end
    xprobe("sm:cast done")
    local now = izi.now()
    if ok == true then
        last_cast[e.key] = now
        local cqm = mod("castq")
        if not (cqm and type(cqm.off_gcd) == "function" and cqm.off_gcd(e.id, sp)) then last_gcd_cast = now end
        if e.name == "Shoot" then
            wand_guid = unit and safe(unit.get_guid, unit) or nil
        elseif e.name == "Auto Shot" then
            shot_guid = unit and safe(unit.get_guid, unit) or nil
        elseif not e.self then
            wand_guid = nil
        end
        -- FROST NOVA, THEN BACK OFF (2.97.0): mage only, never in Rotation
        -- Only (the player steers there).
        if e.name == "Frost Nova" and built.class == enums.class_id.MAGE and not rotation_only() then
            local mv = mod("movement")
            if mv and type(mv.backpedal) == "function" then
                mv.backpedal(2.5)
            end
        end
        note(e.name)
        return true
    end
    if locked then
        local mv = mod("movement")
        if mv and type(mv.release) == "function" then pcall(mv.release) end
    end
    fail_until[e.key] = now + (SELF_ROLES[e.role] and e.role ~= "heal" and e.role ~= "defensive"
        and BUFF_FAIL_GAP or FAIL_GAP)
    return false
end

--- Line of sight to `unit` (2.78.0): no cast is sent into a wall.
local function sees(unit)
    local mv = mod("movement")
    if not mv or type(mv.has_los) ~= "function" then return true end
    xprobe("sm:los")
    return mv.has_los(P, unit) == true
end

local function in_reach(e, unit)
    if e.self then return true end
    if not unit then return false end
    local def = e.def
    if type(def.min) == "number" and def.min > 0 then
        -- The spell's own minimum range when the spellbook reports one
        -- (2.120.0), but never inside the catalog's: the Hunter's 11-yard
        -- melee band (2.222.0) is wider than the game's 8-yard dead zone.
        local mn = def.min
        local sp0 = spell_of(e)
        local real = sp0 and tonumber(safe(function() return sp0.minimum_range end)) or nil
        if real and real > mn and real < 20 then mn = real end
        if c.dist() <= mn then
            return false
        end
    end
    if not sees(unit) then
        return false
    end
    if def.melee then
        return range.melee(unit, 5) == true
    end
    -- THE RANGED ATTACK DISTANCE IS THE LIMIT (2.181.0). Every class with a
    -- "Ranged attack distance" / "Shooting distance" slider casts its ranged
    -- spells only at or inside that distance, not at the spell's own longer
    -- reach. Classes without the slider (warrior, rogue, paladin) are not
    -- limited; melee and self spells never are.
    local cap = slider("ranged_yards", nil)
    if type(cap) == "number" and cap > 0 then
        local d = (unit == T) and c.dist() or (safe(P.distance_to, P, unit) or 99)
        if d > cap + 0.5 then
            return false
        end
    end
    local sp = spell_of(e)
    xprobe("sm:range " .. e.name)
    return range.spell(unit, sp) == true
end

-- ============================================================================
-- ROLE CONDITIONS
-- ============================================================================
--- SPELL PREDICTION (2.248.0): predicted hits of AoE entry `e` and, for a
--- ground spell, the most-hits cast position (predict.lua). nil without it.
local function predicted(e)
    local pr = mod("predict")
    if not pr or type(pr.hits) ~= "function" then return nil end
    local sp0 = spell_of(e)
    local ct = sp0 and tonumber(safe(function() return cast_seconds(sp0) end)) or 0
    local mr = sp0 and tonumber(safe(function() return sp0.maximum_range end)) or nil
    return pr.hits(e, P, T, ct, mr)
end

local function aoe_count(e)
    local def = e.def
    -- 2.248.0: the spell_prediction count first, the radius count without it
    local h = predicted(e)
    if type(h) == "number" then return h end
    if def.center == "self" or def.self then
        return c.near(def.r or 10)
    end
    return c.near_target(def.r or 10)
end

local function mainhand_imbued()
    local v = safe(P.item_has_enchant, P, 16)
    if type(v) == "boolean" then return v end
    local id = safe(P.item_enchant_id, P, 16)
    if type(id) == "number" then return id > 0 end
    local exp = safe(P.item_enchant_expiration, P, 16)
    if type(exp) == "number" then return exp > 0 end
    return nil
end

local COND = {}

function COND.heal(e)
    if c.hp() >= (e.def.hp or c.heal_pct()) then return false end
    if e.def.hot and c.buff(e.name) then return false end
    return true
end

function COND.defensive(e)
    return c.hp() < (e.def.hp or c.def_pct())
end

function COND.interrupt(e)
    return T ~= nil and safe(T.is_channeling_or_casting, T) == true
end

function COND.resource(e)
    return c.in_combat()
end

function COND.opener(e)
    return T ~= nil and not c.in_combat()
end

function COND.execute(e)
    return T ~= nil and c.thp() < (e.def.thp or 20)
end

function COND.control(e)
    return c.in_combat()
end

function COND.debuff(e)
    if not T then return false end
    if c.thp() < (e.def.thp or 25) then return false end
    return auras.debuff_up(T, e.ids) ~= true
end

function COND.totem(e)
    if not c.in_combat() or not T then return false end
    local last = last_cast[e.key]
    return last == nil or (izi.now() - last) >= (e.def.recast or 60)
end

function COND.cooldown(e)
    if not c.in_combat() or not T then return false end
    return c.thp() >= 50 or c.near(10) >= 2
end

function COND.aoe(e)
    -- The Spells-tab "Area of effect at enemies" slider is the count.
    -- A catalog `n` is only the fallback when that slider is missing.
    local need = c.aoe_n()
    if type(need) ~= "number" then need = e.def.n or 3 end
    return T ~= nil and aoe_count(e) >= need
end

function COND.finisher(e)
    if not T then return false end
    if e.def.thp and c.thp() < e.def.thp then return false end
    local cp = c.cp()
    local need = e.def.cp or 4
    return cp >= need or (cp >= 2 and c.thp() < 25)
end

--- Low on mana with a ticked wand: spells wait, the wand fires.
local function wand_time()
    if memo.wand ~= nil then return memo.wand end
    local on = false
    local list = built.by_role.filler
    -- 2.197.0: only with a wand in the ranged slot (targeting caches it 2 s).
    local tg = mod("targeting")
    local has_wand = tg ~= nil and type(tg.has_wand_equipped) == "function"
        and tg.has_wand_equipped(P) == true
    if list and has_wand and c.mana() < c.wand_pct() then
        for i = 1, #list do
            if list[i].name == "Shoot" and usable(list[i]) then
                on = true
                break
            end
        end
    end
    memo.wand = on
    return on
end

function COND.damage(e)
    return T ~= nil and not wand_time()
end

function COND.filler(e)
    if not T then return false end
    if e.name == "Shoot" then
        if not wand_time() then return false end
        local g = safe(T.get_guid, T)
        return g == nil or g ~= wand_guid
    end
    if e.name == "Auto Shot" then
        local g = safe(T.get_guid, T)
        return g == nil or g ~= shot_guid
    end
    return true
end

--- Is the seal worth casting right now: in combat, hitting a live target.
function COND.seal(e)
    if not T or not c.in_combat() then return false end
    if safe(T.is_dead_or_ghost, T) == true then return false end
    if c.dist() > SEAL_REACH then return false end
    if (izi.now() - seal_cast_at) < SEAL_LATCH then return false end
    return not c.group_up("seal")
end

--- Buff-type roles: missing from the player?
local function buff_missing(e)
    local role = e.role
    if role == "imbue" then
        return mainhand_imbued() == false
    end
    if role == "form" then
        local want = FORM_OF[e.name] or STANCE_OF[e.name]
        if want then
            if want == "cat" or want == "bear" then
                -- Feral forms are for fighting: taken when combat starts.
                if not c.in_combat() then return false end
            end
            local cur = c.form()
            if cur == false then return false end   -- unreadable: never guess
            return cur ~= want
        end
    end
    return auras.buff_up(P, e.ids) ~= true
end

local no_cast = { since = nil, logged = -1e9 }
local NO_CAST_S, NO_CAST_GAP = 3.0, 10.0
--- Is `e` ready to go out this tick? false + why while it waits for its
--- resource or the global cooldown (no fail gap for either).
local function ready_now(e)
    if e.name == "Auto Shot" then return true end      -- a toggle, not a GCD cast
    local cq = mod("castq")
    local id = e.id
    local sp = spell_of(e)
    local off = cq and type(cq.off_gcd) == "function" and cq.off_gcd(id, sp) or false
    if not off then
        local t = izi.now()
        if t - last_gcd_cast < GCD_LATENCY then return false, "just cast, waiting for the GCD" end
        local g = tonumber(safe(P.gcd_remains, P))
        if g and g > 0.05 then
            -- with the spell queue, the next spell is queued in the GCD's last moments
            local window = (queue_on() and cq and cq.QUEUE_WINDOW) or 0
            if g > window then return false, string.format("GCD %.1f s", g) end
        end
    end
    local costs = safe(function() return core.spell_book.get_spell_costs(id) end)
    if type(costs) == "table" then
        for i = 1, #costs do
            local k = costs[i]
            if type(k) == "table" and (k.required_buff_id or 0) == 0 and tonumber(k.cost) and k.cost > 0
                and tonumber(k.cost_type) then
                local have = tonumber(safe(P.get_power, P, k.cost_type))
                if have and have < k.cost then
                    return false, string.format("pooling %s %d/%d", POWER_NAMES[k.cost_type] or ("power " .. k.cost_type),
                        have, k.cost)
                end
            end
        end
    end
    return true
end

local function try(e, role_cond)
    if not usable(e) then why_not[e.name] = "unticked / not in use" return false end
    local now = izi.now()
    if (fail_until[e.key] or 0) > now then why_not[e.name] = "failed, retry soon" return false end
    local def = e.def
    if not form_ok(def) then why_not[e.name] = "wrong form / stance" return false end
    if role_cond and not role_cond(e) then why_not[e.name] = "role condition (" .. tostring(e.role) .. ")" return false end
    if def.when and safe(def.when, c) ~= true then why_not[e.name] = "its condition" return false end
    if not ctype_ok(def) then why_not[e.name] = "creature type" return false end
    local rdy, rwhy = ready_now(e)
    if not rdy then why_not[e.name] = rwhy return false end
    why_not[e.name] = "cast refused"
    -- EITHER (2.244.0): a spell whose target is not known (Eureka!) - the
    -- enemy first, then the player.
    if def.either then
        if T and cast(e, T) == true then return true end
        fail_until[e.key] = nil
        return cast(e, P) == true
    end
    local unit = e.self and P or T
    if not in_reach(e, unit) then why_not[e.name] = "out of reach / not in sight" return false end
    local pos = nil
    if def.ground then
        -- 2.248.0: the spell_prediction MOST_HITS position first (predict.lua)
        local _, ppos = predicted(e)
        pos = ppos
        -- 2.245.0: aimed where the target WILL be when the spell lands - its
        -- cast time (a channel: 1 s into it) plus 0.3 s, at most 2 s ahead -
        -- by the documented future position (geometry.future_position).
        local sp0 = spell_of(e)
        local lead = (sp0 and tonumber(safe(function() return cast_seconds(sp0) end)) or 0)
            + (CHANNEL[e.name] and 1.0 or 0.3)
        if lead > 2.0 then lead = 2.0 end
        local geo = mod("geometry")
        pos = pos or (T and geo and type(geo.future_position) == "function" and geo.future_position(T, lead)) or nil
        if not pos then pos = T and safe(T.get_position, T) or nil end
        if not pos then return false end
    end
    return cast(e, unit, pos)
end

-- ============================================================================
-- UPKEEP - buffs, forms, stances, imbues, pet
-- ============================================================================
local UPKEEP_ROLES = { "form", "buff", "cbuff", "imbue" }

local function is_resting()
    local healing = mod("healing")
    if healing and type(healing.is_resting) == "function" and healing.is_resting() == true then
        return true
    end
    local cons = mod("data/consumables")
    if cons then
        if type(cons.FOOD_AURA_IDS) == "table" and auras.buff_up(P, cons.FOOD_AURA_IDS) then return true end
        if type(cons.DRINK_AURA_IDS) == "table" and auras.buff_up(P, cons.DRINK_AURA_IDS) then return true end
    end
    return false
end

local pet_fail_until = 0

-- HUNTER PET (2.222.0): Call Pet 883 / Revive Pet 982, hard-coded, so a
-- dismissed pet is called and a dead one revived whether or not the spell
-- scan found them (pets.hunter_pet). The Spells-tab "Call Pet" tick still
-- switches pet handling off.
local HUNTER_PET = {
    call = { name = "Call Pet", role = "pet", id = 883, ids = { 883 }, self = true,
        key = "Call Pet|hunter", def = {} },
    revive = { name = "Revive Pet", role = "pet", id = 982, ids = { 982 }, self = true,
        key = "Revive Pet|hunter", def = {} },
    cast = function(x) return cast(x, P) == true end,
}

local function pet_upkeep()
    local pets = mod("pets")
    if not pets then return false end
    if built.class == enums.class_id.HUNTER and type(pets.hunter_pet) == "function"
        and smart.is_enabled("Call Pet", true) then
        local r = pets.hunter_pet(P, HUNTER_PET)
        if r ~= nil then return r == true end
    end
    local summon = nil
    local members = built.by_role.pet
    if members then
        for i = 1, #members do
            if usable(members[i]) then
                summon = members[i]
                break
            end
        end
    end
    if not summon then return false end
    if izi.now() < pet_fail_until then return false end
    if built.class == enums.class_id.HUNTER then
        pcall(pets.passive, P)
    end
    local heal = nil
    local hl = built.by_role.petheal
    if hl and hl[1] and usable(hl[1]) then heal = hl[1] end
    local revive = nil
    if built.class == enums.class_id.HUNTER and spellbook.family("Revive Pet") then
        revive = { name = "Revive Pet", role = "pet", id = spellbook.family("Revive Pet").id,
            ids = ranks_of("Revive Pet"), self = true, key = "Revive Pet|pet", def = {} }
    end
    local function learned(x) return x ~= nil end
    -- pets.maintain calls cast_self(spell, player, label).
    local function cast_self(x)
        if cast(x, P) then return true end
        pet_fail_until = izi.now() + 15
        return false
    end
    local acted = pets.maintain(P, {
        summon = summon, summon_label = summon.name,
        revive = revive,
        heal = heal, heal_ids = heal and heal.ids or nil,
        heal_label = heal and heal.name or nil,
        heal_pct = slider("pet_heal_pct", 50),
        learned = learned, cast_self = cast_self,
        min_level = (built.class == enums.class_id.HUNTER) and 10 or nil,
    })
    return acted == true
end

local function upkeep_step(in_combat)
    local now = izi.now()
    if (now - last_upkeep) < UPKEEP_GAP then return false end
    for r = 1, #UPKEEP_ROLES do
        local role = UPKEEP_ROLES[r]
        if not (role == "cbuff" and not in_combat) then
            local bucket = built.by_role[role]
            if bucket then
                for i = 1, #bucket do
                    local e = bucket[i]
                    if try(e, buff_missing) then
                        last_upkeep = now
                        state.set_note("Buff", e.name)
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- Keep every ticked buff up. Called every tick by all three modes, in and
--- out of combat. Returns true when it cast something.
-- ============================================================================
-- BUFF RANDOMS (2.91.0)
-- ============================================================================
-- With "Buff Randoms" ticked, a mage out of combat hands Arcane Intellect
-- (spell 1459, Rank 1 - see random_buff) to
-- friendly players nearby who have neither it nor Arcane Brilliance. Never
-- in a fight, while resting or mounted, or under RANDOM_MANA mana; one player
-- per RANDOM_GAP; a player buffed is left alone for RANDOM_DONE, one that
-- could not be buffed (too low for the rank, out of reach) for RANDOM_FAIL.
local RANDOM_RANGE = 30
local RANDOM_GAP = 4.0
local RANDOM_DONE = 600
local RANDOM_FAIL = 300
local RANDOM_MANA = 50
local RANDOM_SPELL_ID = 1459     -- Arcane Intellect, Rank 1
local random_spell = nil
local random_next = 0
local random_seen = {}         -- guid -> time before which the player is skipped
local random_seen_n = 0

local function buff_randoms_on()
    local gui = mod("gui")
    return gui ~= nil and type(gui.is_on) == "function" and gui.is_on("buff_randoms") == true
end

local function random_buff()
    if built.class ~= enums.class_id.MAGE or not buff_randoms_on() then return false end
    local now = izi.now()
    if now < random_next then return false end
    random_next = now + 1.0
    if c.mana() < RANDOM_MANA then return false end
    local ai = nil
    local list = built.by_role.buff
    if list then
        for i = 1, #list do
            if list[i].name == "Arcane Intellect" then ai = list[i] break end
        end
    end
    if not ai then return false end
    -- Rank 1, spell 1459, for strangers (2.92.0): any level can take it, so
    -- a low-level player never refuses the cast the way a high rank would.
    local known = false
    for i = 1, #ai.ids do
        if ai.ids[i] == RANDOM_SPELL_ID then known = true break end
    end
    if not known then return false end
    if random_spell == nil then
        random_spell = safe(izi.spell, RANDOM_SPELL_ID) or false
    end
    local sp = random_spell or nil
    if not sp or safe(sp.cooldown_up, sp) == false then return false end
    local ai_ids = ai.ids
    local ab_ids = ranks_of("Arcane Brilliance")
    local targeting = mod("targeting")
    local objs = targeting and type(targeting.visible_objects) == "function" and targeting.visible_objects() or nil
    if type(objs) ~= "table" then return false end
    local mv = mod("movement")
    local my_guid = safe(P.get_guid, P)
    local best, best_d = nil, nil
    for i = 1, #objs do
        local u = objs[i]
        if u and safe(u.is_valid, u) == true and safe(u.is_player, u) == true then
            local g = safe(u.get_guid, u)
            if g ~= nil and g ~= my_guid and (random_seen[g] or 0) <= now
                and safe(u.is_dead_or_ghost, u) ~= true
                and safe(P.can_attack, P, u) ~= true then
                local d = safe(P.distance_to, P, u)
                if type(d) == "number" and d <= RANDOM_RANGE and (best_d == nil or d < best_d)
                    and auras.buff_up(u, ai_ids) ~= true
                    and not (ab_ids and auras.buff_up(u, ab_ids) == true) then
                    best, best_d = u, d
                end
            end
        end
    end
    if not best then return false end
    if mv and type(mv.has_los) == "function" and mv.has_los(P, best) ~= true then return false end
    local g = safe(best.get_guid, best)
    if random_seen_n > 200 then random_seen, random_seen_n = {}, 0 end
    random_seen_n = random_seen_n + 1
    random_next = now + RANDOM_GAP
    local ok = safe(function() return spellcheck.cast_safe(sp, best, "Arcane Intellect") end)
    if ok == true then
        random_seen[g] = now + RANDOM_DONE
        state.set_note("Buff", "Arcane Intellect on " .. tostring(safe(best.get_name, best) or "a player"))
        note("Arcane Intellect")
        return true
    end
    random_seen[g] = now + RANDOM_FAIL
    return false
end

function smart.upkeep(player)
    if not player or not spellbook.ready() then return false end
    if safe(player.is_mounted, player) == true then return false end
    -- 2.240.0: never over a cast or a channel. Ice Barrier went out during a
    -- Frostbolt cast (twice, 1 s apart); during Evocation, Blizzard or Arcane
    -- Missiles an instant cancels the channel. smart.combat already waited.
    if safe(player.is_channeling_or_casting, player) == true then return false end
    build(player)
    if #built.list == 0 then return false end
    begin(player, nil, nil)
    if is_resting() then return false end
    local fighting = c.in_combat()
    -- In a fight a heal comes before a rebuff: leave it to the combat
    -- rotation while health is under the heal line.
    if fighting and c.hp() < c.heal_pct() then return false end
    if upkeep_step(fighting) then return true end
    if not fighting and pet_upkeep() then return true end
    if not fighting and random_buff() then return true end
    return false
end

-- ============================================================================
-- COMBAT
-- ============================================================================
local COMBAT_ORDER = {
    { "heal", COND.heal }, { "defensive", COND.defensive }, { "interrupt", COND.interrupt },
    "racials", "upkeep",
    { "seal", COND.seal },
    { "resource", COND.resource }, { "opener", COND.opener }, { "execute", COND.execute },
    { "control", COND.control }, { "debuff", COND.debuff }, { "totem", COND.totem },
    { "cooldown", COND.cooldown }, { "aoe", COND.aoe }, { "finisher", COND.finisher },
    { "damage", COND.damage }, { "filler", COND.filler },
}

--- The AoE bucket sorted by predicted hits, most first (stable).
local aoe_sorted = {}
local function aoe_by_hits(bucket)
    local n = #bucket
    for i = 1, n do
        local e = bucket[i]
        local h = (T and enabled(e)) and aoe_count(e) or 0
        aoe_sorted[i] = { e = e, h = type(h) == "number" and h or 0, i = i }
    end
    for i = #aoe_sorted, n + 1, -1 do aoe_sorted[i] = nil end
    table.sort(aoe_sorted, function(a, b)
        if a.h ~= b.h then return a.h > b.h end
        return a.i < b.i
    end)
    local out = {}
    for i = 1, n do out[i] = aoe_sorted[i].e end
    return out
end

--- Interrupt any caster in the pack, not only the current target.
local function pack_interrupt()
    local bucket = built.by_role.interrupt
    if not bucket or type(PACK) ~= "table" then return false end
    local keep = T
    for i = 1, #PACK do
        local u = PACK[i]
        if u and safe(u.is_channeling_or_casting, u) == true then
            T = u
            for k = 1, #bucket do
                if try(bucket[k], nil) then
                    T = keep
                    return true
                end
            end
        end
    end
    T = keep
    return false
end

-- ============================================================================
-- ROGUE THROW (2.224.0)
-- ============================================================================
-- With "Throw" ticked (Spells tab), Throw (2764) known and a throwing weapon
-- in the ranged slot, a rogue pulls each new target from THROW_STAND yards
-- (inside Throw's 30), once, then holds position until the mob reaches melee
-- and only then starts the ticked melee rotation. rotations/rogue.lua asks
-- smart.rogue_throw_range for its engage distance, which is what makes
-- combat movement stop at the throw distance and stay there.
--   * not thrown within THROW_PLAN s of getting ready (line of sight, a
--     failing cast) -> given up for that target, the rogue closes in;
--   * the mob not in melee THROW_WAIT s after the throw (a caster, a runner,
--     an evading mob) -> the rogue closes in.
local THROW_ID = 2764
local THROW_RANGE = 30
local THROW_STAND = 28
local THROW_PLAN = 6.0
local THROW_WAIT = 8.0
local THROW_MELEE = 5
local RT = { guid = nil, plan_t = nil, thrown_t = nil, done = false,
    e = { name = "Throw", role = "pull", id = THROW_ID, ids = { THROW_ID },
        key = "Throw|pull", def = { on = true } } }

local function throw_ready(player)
    if built.class ~= enums.class_id.ROGUE then return false end
    if not smart.is_enabled("Throw", true) then return false end
    -- A Stealth opener comes first (2.228.0).
    if smart.is_enabled("Stealth", true) and spellbook.family("Stealth") ~= nil
        and safe(player.is_in_combat, player) ~= true then
        return false
    end
    local known = spellbook.family("Throw") ~= nil
        or safe(function() return core.spell_book.is_spell_learned(THROW_ID) end) == true
    if not known then return false end
    local tg = mod("targeting")
    return tg ~= nil and type(tg.has_thrown_equipped) == "function"
        and tg.has_thrown_equipped(player) == true
end

--- Follow the target: a new GUID starts a new pull - only to open a fight.
--- A target picked up while already in combat (an add) is fought in melee;
--- the rogue never walks back out to throw.
local function throw_track(player, target)
    local g = target and safe(target.get_guid, target) or nil
    if g == nil then return nil end
    if g ~= RT.guid then
        RT.guid, RT.plan_t, RT.thrown_t = g, nil, nil
        RT.done = safe(player.is_in_combat, player) == true
    end
    return g
end

--- Can this rogue throw-pull at all right now (ticked, known, equipped)?
function smart.rogue_can_throw(player)
    if not player or not spellbook.ready() then return false end
    build(player)
    return throw_ready(player)
end

--- The rogue's engage distance while a throw pull is under way, else nil.
function smart.rogue_throw_range(player, target)
    if not player or not target or not spellbook.ready() then return nil end
    build(player)
    if built.class ~= enums.class_id.ROGUE then return nil end
    if throw_track(player, target) == nil or RT.done then return nil end
    local now = izi.now()
    local d = safe(player.distance_to, player, target)
    if type(d) == "number" and d <= THROW_MELEE then
        RT.done = true                         -- it came to us: melee now
        return nil
    end
    if RT.thrown_t then
        if (now - RT.thrown_t) >= THROW_WAIT then
            RT.done = true
            state.set_note("Throw", "mob did not come - closing in")
            return nil
        end
        return THROW_STAND                     -- hold: let it come
    end
    if not throw_ready(player) then return nil end
    if RT.plan_t and (now - RT.plan_t) >= THROW_PLAN then
        RT.done = true
        state.set_note("Throw", "no throw landed - closing in")
        return nil
    end
    return THROW_STAND
end

--- Throw at T when the pull calls for it. True when it cast. While waiting
--- for the mob it returns false: the rotation still runs (Evasion on an add),
--- and its melee spells cannot reach from here anyway.
local function rogue_throw()
    if built.class ~= enums.class_id.ROGUE or not T then return false end
    if throw_track(P, T) == nil or RT.done then return false end
    if RT.thrown_t then
        if c.dist() > THROW_MELEE and (izi.now() - RT.thrown_t) < THROW_WAIT then
            state.set_note("Throw", "waiting for the mob to reach melee")
        end
        return false
    end
    if not throw_ready(P) then return false end
    local d = c.dist()
    if d > THROW_RANGE or d <= THROW_MELEE then return false end
    RT.plan_t = RT.plan_t or izi.now()
    if not sees(T) then return false end
    if (fail_until[RT.e.key] or 0) > izi.now() then return false end
    if cast(RT.e, T) then
        RT.thrown_t = izi.now()
        return true
    end
    return false
end

-- ============================================================================
-- ROGUE STEALTH OPENER (2.228.0)
-- ============================================================================
-- With "Stealth" ticked and known, a rogue opening a fight (not in combat)
-- casts Stealth once the target is within STEALTH_AT yards, walks in with
-- no auto attack (targeting.start_auto_attack holds it while stealthed and
-- out of combat), steps into the target's rear arc (movement/combat
-- behind_step, asked through rogue.combat_profile want_behind) and opens
-- with Backstab. Nothing else is cast while it sneaks in, so Stealth holds.
--   * Backstab unticked / unknown           -> no positioning; the first
--     ticked melee spell opens from Stealth;
--   * not behind BEHIND_MAX s after reaching melee -> open with the rotation
--     (Sinister Strike);
--   * Stealth refused / not yet castable    -> no opener for this target;
--   * the fight has begun some other way    -> normal rotation.
-- The Throw pull (above) is skipped while a Stealth opener is wanted.
local STEALTH_AT = 25
local STEALTH_MELEE = 5
local BEHIND_MAX = 4.0
local SO = { guid = nil, reached_t = nil, done = false }

local function entry_named(name)
    local list = built.list
    for i = 1, #list do
        if list[i].name == name then return list[i] end
    end
    return nil
end

local function stealth_entry()
    local e = entry_named("Stealth")
    if e and usable(e) then return e end
    return nil
end

local function backstab_entry()
    local e = entry_named("Backstab")
    if e and usable(e) then return e end
    return nil
end

local function is_stealthed(player)
    local v = safe(player.stealth_up, player)
    if type(v) == "boolean" then return v end
    local ids = ranks_of("Stealth")
    return ids ~= nil and auras.buff_up(player, ids) == true
end

--- Is a Stealth opener wanted on `target` (rogue, Stealth ticked + known,
--- not yet in combat, not given up on this target)?
local function stealth_wanted(player, target)
    if built.class ~= enums.class_id.ROGUE or not player or not target then return false end
    local g = safe(target.get_guid, target)
    if g == nil then return false end
    if g ~= SO.guid then
        SO.guid, SO.reached_t = g, nil
        SO.done = safe(player.is_in_combat, player) == true
    end
    if SO.done then return false end
    if safe(player.is_in_combat, player) == true then
        SO.done = true
        return false
    end
    return stealth_entry() ~= nil or is_stealthed(player)
end

--- movement: should the rogue step behind `target` now? (combat profile)
function smart.rogue_wants_behind(player, target)
    if not player or not target or not spellbook.ready() then return false end
    build(player)
    if not stealth_wanted(player, target) or not is_stealthed(player) then return false end
    if not backstab_entry() then return false end
    return not SO.reached_t or (izi.now() - SO.reached_t) < BEHIND_MAX
end

--- Is a Stealth opener under way or wanted (the Throw pull stands aside)?
function smart.rogue_stealth_wanted(player, target)
    if not player or not target or not spellbook.ready() then return false end
    build(player)
    return stealth_wanted(player, target)
end

--- Per combat decision. True = handled (cast, or holding Stealth).
local function rogue_stealth()
    if not stealth_wanted(P, T) then return false end
    local now = izi.now()
    local d = c.dist()
    if not is_stealthed(P) then
        if d > STEALTH_AT then return false end
        local e = stealth_entry()
        if e and (fail_until[e.key] or 0) <= now and cast(e, P) then
            state.set_note("Stealth", "sneaking in")
            return true
        end
        SO.done = true                     -- cannot stealth now: open normally
        return false
    end
    if d <= STEALTH_MELEE then SO.reached_t = SO.reached_t or now end
    local bs = backstab_entry()
    if bs then
        if d <= STEALTH_MELEE and c.behind() then
            if try(bs, nil) then
                SO.done = true
                return true
            end
        end
        if SO.reached_t and (now - SO.reached_t) >= BEHIND_MAX then
            SO.done = true                 -- could not get behind: open from the front
            state.set_note("Stealth", "not behind - opening from the front")
            return false
        end
        state.set_note("Stealth", d <= STEALTH_MELEE and "getting behind" or "sneaking in")
        return true                        -- hold: nothing that breaks Stealth
    end
    -- No Backstab: the first ticked melee spell opens once in reach.
    if d <= STEALTH_MELEE then
        SO.done = true
        return false
    end
    return true
end

--- One combat decision. `ctx.enemies` is the pack the caller scanned.
function smart.combat(player, target, ctx)
    if not player or not spellbook.ready() then return false end
    build(player)
    if #built.list == 0 then return false end
    -- The pet goes in first (2.225.0): before the "already casting" return,
    -- so a hunter opening with a cast still sends the pet at the mob.
    local pets = mod("pets")
    if pets and target and (built.class == enums.class_id.HUNTER or built.class == enums.class_id.WARLOCK) then
        xprobe("sm:pet attack")
        pcall(pets.attack, player, target)
    end
    -- QUEUE AHEAD (2.249.0): with the spell queue the next spell is picked in
    -- the last moments of a cast (castq.may_queue), so it goes out the moment
    -- the cast ends. Never during a channel.
    local cq = queue_on()
    if cq and type(cq.check_stuck) == "function" then
        cq.check_stuck(function(msg)
            core.log_warning("[Master Farmer - Grindbot] " .. msg)
            local el = mod("errorlog")
            if el and type(el.trail) == "function" then pcall(el.trail, "rotation", "%s", msg) end
        end)
        cq = queue_on()
    end
    if cq then
        if not cq.may_queue(player) then return true end
    elseif safe(player.is_channeling_or_casting, player) == true then
        return true
    end
    begin(player, target, ctx and ctx.enemies or nil)

    -- Rogue Stealth opener (2.228.0), else the throw pull (2.224.0).
    if rogue_stealth() then return true end
    if rogue_throw() then return true end

    -- Spells cast at their own range (in_reach). They are not held back until
    -- the walk finishes: the moment the focused target is in range, the
    -- ticked spell fires.
    for i = 1, #COMBAT_ORDER do
        local step = COMBAT_ORDER[i]
        if step == "racials" then
            local racials = mod("racials")
            xprobe("sm:racials")
            if racials and type(racials.tick) == "function" and racials.tick(player, target, ctx) then
                return true
            end
        elseif step == "upkeep" then
            if upkeep_step(true) then return true end
        else
            local role, cond = step[1], step[2]
            if role == "interrupt" and pack_interrupt() then return true end
            local bucket = built.by_role[role]
            -- MOST HITS FIRST (2.248.0): the AoE spells in the order of their
            -- predicted hits (spell_prediction), list order among equals.
            if bucket and role == "aoe" and #bucket > 1 then
                bucket = aoe_by_hits(bucket)
            end
            if bucket then
                for k = 1, #bucket do
                    local e = bucket[k]
                    if try(e, cond) then
                        if role == "seal" then seal_cast_at = izi.now() end
                        no_cast.since = nil
                        return true
                    end
                end
            end
        end
    end
    -- NOTHING CAST (2.251.0): in a fight with a target and no spell for
    -- NO_CAST_S, say why each spell was passed over (every NO_CAST_GAP).
    if T and c.in_combat() then
        local t = izi.now()
        no_cast.since = no_cast.since or t
        if t - no_cast.since >= NO_CAST_S and t - no_cast.logged >= NO_CAST_GAP then
            no_cast.logged = t
            local parts = {}
            for i = 1, #built.list do
                local e = built.list[i]
                if not SELF_ROLES[e.role] or e.role == "heal" then
                    parts[#parts + 1] = e.name .. ": " .. tostring(why_not[e.name] or "not tried")
                end
            end
            local el = mod("errorlog")
            if el and type(el.trail) == "function" then
                pcall(el.trail, "rotation", "nothing cast for %.0f s at %s (%.1f yd, power %s, combo %s, queue %s): %s",
                    t - no_cast.since, tostring(safe(T.get_name, T)), c.dist() or -1, tostring(safe(P.get_power, P, 3) or c.mana()),
                    tostring(c.cp()), queue_on() and "on" or "off", table.concat(parts, "; "))
            end
        end
    else
        no_cast.since = nil
    end
    return false
end

-- ============================================================================
-- REACH OF THE TICKED DAMAGE SPELLS (2.90.0)
-- ============================================================================
local reach_cache = { scan = -1, yards = nil }

--- The longest range among the ticked, ranged damage spells, or nil.
function smart.max_range(player)
    if not player or not spellbook.ready() then return nil end
    build(player)
    if reach_cache.scan == built.scan and reach_cache.picks == picks.count() then
        return reach_cache.yards
    end
    local best = nil
    local roles = { "damage", "debuff", "filler" }
    for r = 1, #roles do
        local bucket = built.by_role[roles[r]]
        if bucket then
            for i = 1, #bucket do
                local e = bucket[i]
                if not e.self and not e.def.melee and enabled(e) then
                    local sp = spell_of(e)
                    local yd = sp and tonumber(safe(function() return sp.maximum_range end)) or nil
                    if yd and yd > 5 and (best == nil or yd > best) then
                        best = yd
                    end
                end
            end
        end
    end
    reach_cache.scan, reach_cache.picks, reach_cache.yards = built.scan, picks.count(), best
    return best
end

-- ============================================================================
-- CLASS SHAPE
-- ============================================================================
--- Does the ticked set make this character fight in melee? nil = no opinion
--- (the class module decides).
function smart.is_melee(player)
    if not player or not spellbook.ready() then return nil end
    build(player)
    if built.class == enums.class_id.DRUID then
        local f = chosen("form")
        return f ~= nil and (FORM_OF[f.name] == "cat" or FORM_OF[f.name] == "bear")
    end
    -- Shaman stands at Lightning Bolt range and melees only once the mob
    -- has closed. Stormstrike being ticked does not pull the approach in.
    if built.class == enums.class_id.SHAMAN then
        return false
    end
    return nil
end

-- ============================================================================
-- SPELLS TAB
-- ============================================================================
--- The rows the Spells tab draws: every known class spell and racial, with
--- whether it is ticked and whether it is the group's active member.
--- 2.242.0: what an uncatalogued spell is for, from its description:
--- "dps" (it deals damage), "heal" (it heals and deals no damage) or nil.
--- Never "aoe": area damage is only what the class catalog says it is.
function smart.spell_use(desc)
    if type(desc) ~= "string" or desc == "" then return nil end
    local d = desc:lower()
    if d:find("damage", 1, true) then return "dps" end
    if d:find("heal", 1, true) or d:find("restores %d") and d:find("health", 1, true) then return "heal" end
    return nil
end

function smart.rows(player)
    if not player or not spellbook.ready() then return nil end
    build(player)
    return built.rows
end

function smart.row_state(row)
    local on = smart.is_enabled(row.name, row.default)
    local active = on
    if on and row.group then
        local ch = chosen(row.group)
        active = ch ~= nil and ch.name == row.name
    end
    return on, active
end

function smart.toggle(row)
    local on = smart.is_enabled(row.name, row.default)
    picks.set(row.name, not on)
    fail_until = {}
    mark_dirty()
end

function smart.class_key(player)
    return catalog.class_key(player and player_class(player) or nil)
end

-- For offline tests: the condition context and its per-call reset.
smart._c = c
smart._begin = begin

function smart.reset()
    built = { scan = -1, class = nil, race = nil, list = {}, by_role = {}, rows = {}, groups = {} }
    spell_cache = {}
    fail_until = {}
    last_cast = {}
end

return smart
