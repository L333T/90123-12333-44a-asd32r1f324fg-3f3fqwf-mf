-- ============================================================================
-- Master Farmer - Grindbot
-- Adaptive rotation - learns what kills fastest, per character
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.277.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHAT (2.274.0, GUI "Adaptive Rotation", Spells tab, on by default)
--   Every class's rotation (smart.lua) reads this module to cast the spells
--   that kill the target soonest:
--
--   READ  - every spell the player casts is seen through
--           core.register_on_spell_cast_callback (the bot's casts and the
--           player's own, in Rotation Only), and the target's health drop
--           that follows is measured as that spell's damage.
--   KNOW  - a spell the character has just learned starts from the damage
--           written in its description ("causing 20 to 22 Frost damage",
--           "40 Shadow damage over 12 sec", "weapon damage plus 3"), turned
--           into the damage this target will take by health_prediction's
--           speculate_damage. After MIN_SAMPLES measured hits the measured
--           average is used instead.
--   ORDER - the damage, filler, finisher and execute spells are tried by
--           damage per second of casting (cast time, at least the GCD); with
--           mana under LOW_MANA % by damage per mana. A spell that kills the
--           target NOW is tried first, the fastest cast first.
--   SKIP  - a DoT whose fight is shorter than half its duration, and a long
--           cooldown when combat_forecast says the fight is too short, are
--           passed over; a cast whose target health_prediction says will be
--           dead before it lands is passed over; a melee character's
--           cast-time spell waits for the swing it would otherwise clip
--           (auto_attack_helper).
--   SAVE  - all of it is saved per character GUID in
--           scripts_data/mfg/adapt_<guid>.txt and loaded again whenever that
--           character is played. A new rank (trainer, level-up) re-reads the
--           description and rescales what was measured for the old rank.
--
--   The Spells tab still decides WHICH spells are used and in which role
--   order (heals, defensives, interrupts, debuffs, then damage); this module
--   only re-orders spells inside a role and gates the ones listed above.
-- ============================================================================

local adapt = {}

local ok_izi, izi = pcall(require, "common/izi_sdk")

local FOLDER = "mfg"
local PLUGIN = "Master Farmer - Grindbot"
local MIN_SAMPLES = 3         -- measured hits before the measured average is trusted
local ALPHA = 0.2             -- moving-average weight of a new hit
local LAND_WINDOW = 1.6       -- s after the cast time a health drop still belongs to the cast
local SWING_GAP = 0.08        -- s: a drop this close to an auto attack is not measured
local LOW_MANA = 30           -- % mana under which spells are ordered by damage per mana
local KILL_MARGIN = 0.85      -- a "kills now" spell must do 1/0.85 of the target's health
local SAVE_GAP = 30           -- s between two saves of a changed profile
local WEAPON_FLOOR = 5        -- weapon hit estimate: WEAPON_FLOOR + 2 x level
local GCD = 1.5

local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function now()
    if ok_izi and type(izi) == "table" and type(izi.now) == "function" then
        local t = safe(izi.now)
        if type(t) == "number" then return t end
    end
    return safe(core.time) or 0
end

local function mod(name)
    local m = package.loaded[name]
    if type(m) == "table" then return m end
    local ok, r = pcall(require, name)
    if ok and type(r) == "table" then return r end
    return nil
end

local function trail(fmt, ...)
    local el = mod("errorlog")
    if el and type(el.trail) == "function" then pcall(el.trail, "rotation", fmt, ...) end
end

-- The Sylvanas modules, each optional: without one, its part is skipped.
local function lib(name)
    local ok, m = pcall(require, name)
    if ok and m ~= nil and (type(m) == "table" or type(m) == "userdata") then return m end
    return nil
end
local forecast = lib("common/modules/combat_forecast")
local health_pred = lib("common/modules/health_prediction")
local auto_attack = lib("common/utility/auto_attack_helper")

-- ----------------------------------------------------------------------------
-- STATE
-- ----------------------------------------------------------------------------
-- profile = { guid, class, level, kills, ttk, spells = { [name] = st } }
-- st = { id, role, pd (description damage), pdot, dd (dot seconds), weapon,
--        n (measured hits), avg (measured damage), casts }
local profile = nil
local dirty, saved_t = false, -1e9
local id_name = {}            -- spell id (any rank) -> spell name
local pending = {}            -- casts waiting for their damage to land
local hp_guid, hp_last = nil, nil
local fight = { guid = nil, t = nil }
local spec_cache = {}         -- target guid .. id -> { t, v }
local ct_fn = nil             -- smart.lua's cast time of an entry
local last_order = ""

function adapt.enabled()
    local g = mod("gui")
    if g and type(g.is_on) == "function" then
        return g.is_on("adaptive") ~= false
    end
    return true
end

-- ----------------------------------------------------------------------------
-- DESCRIPTION -> DAMAGE
-- ----------------------------------------------------------------------------
--- Damage written in a spell description: direct (average of "X to Y"),
--- over-time total and its seconds, and whether weapon damage adds to it.
function adapt.parse_description(desc)
    if type(desc) ~= "string" or desc == "" then return 0, 0, 0, false end
    local d = desc:lower():gsub("(%d),(%d%d%d)", "%1%2")
    local dot, dur = 0, 0
    -- "40 shadow damage over 12 sec", "an additional 2 fire damage over 4 sec"
    d = d:gsub("(%d+)( [%a ]-damage over )(%d+)( sec)", function(a, _, s)
        dot = dot + tonumber(a)
        if tonumber(s) > dur then dur = tonumber(s) end
        return ""
    end)
    local direct = 0
    for a, b in d:gmatch("(%d+) to (%d+)[%a ]-damage") do
        direct = direct + (tonumber(a) + tonumber(b)) / 2
    end
    if direct == 0 then
        local single = d:match("causing (%d+) [%a ]-damage") or d:match("deals (%d+) [%a ]-damage")
            or d:match("for (%d+) [%a ]-damage") or d:match("inflicts (%d+) [%a ]-damage")
            or d:match("causes (%d+) [%a ]-damage") or d:match("(%d+) [%a ]-damage in addition")
        if single then direct = tonumber(single) end
    end
    local weapon = d:find("weapon damage", 1, true) ~= nil or d:find("normal damage", 1, true) ~= nil
    if weapon then
        local plus = d:match("weapon damage plus (%d+)") or d:match("damage plus (%d+)")
            or d:match("plus an additional (%d+)") or d:match("plus (%d+)")
        if plus and direct == 0 then direct = tonumber(plus) end
    end
    return direct, dot, dur, weapon
end

local function prior_of(st, level)
    local d = st.pd or 0
    if st.weapon then d = d + WEAPON_FLOOR + 2 * (level or 1) end
    return d
end

-- ----------------------------------------------------------------------------
-- PROFILE FILE (one per character GUID)
-- ----------------------------------------------------------------------------
local function file_for(guid)
    return FOLDER .. "/adapt_" .. tostring(guid):gsub("[^%w%-_]", "_") .. ".txt"
end
adapt.file_for = file_for

local function clean(s)
    return (tostring(s or ""):gsub("[;\r\n=]", " "))
end

local function serialise(p)
    local lines = {
        "# Master Farmer - Grindbot adaptive rotation. Rewritten automatically.",
        "guid=" .. clean(p.guid),
        "class=" .. tostring(p.class or ""),
        "level=" .. tostring(p.level or ""),
        "kills=" .. tostring(p.kills or 0),
        string.format("ttk=%.2f", p.ttk or 0),
        "order=" .. clean(p.order or ""),
    }
    local names = {}
    for name in pairs(p.spells) do names[#names + 1] = name end
    table.sort(names)
    for i = 1, #names do
        local st = p.spells[names[i]]
        lines[#lines + 1] = string.format("spell=%s;%s;%d;%s;%.1f;%.1f;%.1f;%d;%d;%.1f",
            clean(names[i]), clean(st.role), st.id or 0, st.weapon and "w" or "-",
            st.pd or 0, st.pdot or 0, st.dd or 0, st.n or 0, st.casts or 0, st.avg or 0)
    end
    return table.concat(lines, "\n") .. "\n"
end
adapt._serialise = serialise

local function parse(text)
    local p = { spells = {} }
    for line in tostring(text):gmatch("[^\r\n]+") do
        local k, v = line:match("^(%a+)=(.*)$")
        if k == "spell" then
            local f = {}
            for part in (v .. ";"):gmatch("([^;]*);") do f[#f + 1] = part end
            if #f >= 10 and f[1] ~= "" then
                p.spells[f[1]] = {
                    role = f[2], id = tonumber(f[3]) or 0, weapon = f[4] == "w",
                    pd = tonumber(f[5]) or 0, pdot = tonumber(f[6]) or 0, dd = tonumber(f[7]) or 0,
                    n = tonumber(f[8]) or 0, casts = tonumber(f[9]) or 0, avg = tonumber(f[10]) or 0,
                }
            end
        elseif k == "guid" then p.guid = v
        elseif k == "class" then p.class = tonumber(v)
        elseif k == "level" then p.level = tonumber(v)
        elseif k == "kills" then p.kills = tonumber(v) or 0
        elseif k == "ttk" then p.ttk = tonumber(v) or 0
        elseif k == "order" then p.order = v
        end
    end
    return p
end
adapt._parse = parse

function adapt.save(force)
    if not profile or not profile.guid then return false end
    if not dirty and not force then return false end
    local t = now()
    if not force and t - saved_t < SAVE_GAP then return false end
    saved_t = t
    local path = file_for(profile.guid)
    pcall(function() core.create_data_file(path) end)
    local ok = pcall(function() core.write_data_file(path, serialise(profile)) end)
    if ok then dirty = false end
    return ok
end

local function load_for(guid, class)
    local text = safe(function() return core.read_data_file(file_for(guid)) end)
    local p = nil
    if type(text) == "string" and text ~= "" then
        p = parse(text)
        if p.guid ~= guid then p = nil end
    end
    p = p or { spells = {}, kills = 0, ttk = 0 }
    p.guid, p.class = guid, class or p.class
    p.kills, p.ttk = p.kills or 0, p.ttk or 0
    return p
end

-- ----------------------------------------------------------------------------
-- SYNC WITH THE SPELL BOOK (smart.lua build: a new character, a new spell,
-- a new rank)
-- ----------------------------------------------------------------------------
local OFFENSIVE = { damage = true, filler = true, finisher = true, execute = true,
    debuff = true, cooldown = true, aoe = true, opener = true, control = true, other_dps = true }

--- `list` = smart's built entries ({ name, role, id, ids, self }).
function adapt.sync(player, list)
    if not player or type(list) ~= "table" then return end
    local guid = safe(player.get_guid, player)
    if type(guid) ~= "string" or guid == "" then return end
    local level = safe(player.get_level, player)
    if not profile or profile.guid ~= guid then
        if profile then adapt.save(true) end
        profile = load_for(guid, safe(player.get_class, player))
        pending, hp_guid, hp_last, last_order = {}, nil, nil, ""
        local n = 0
        for _ in pairs(profile.spells) do n = n + 1 end
        local name = safe(player.get_name, player) or guid
        core.log(string.format("[%s] Adaptive rotation: %s profile for %s - %d spells, %d kills%s.",
            PLUGIN, n > 0 and "loaded the" or "new", tostring(name), n, profile.kills or 0,
            (profile.ttk or 0) > 0 and string.format(", %.1f s a kill", profile.ttk) or ""))
    end
    profile.level = level or profile.level
    id_name = {}
    local learned = {}
    for i = 1, #list do
        local e = list[i]
        if e and e.name and OFFENSIVE[e.role] and not e.self then
            for k = 1, #(e.ids or {}) do id_name[e.ids[k]] = e.name end
            id_name[e.id] = e.name
            local st = profile.spells[e.name]
            if not st or st.id ~= e.id then
                local desc = safe(function() return core.spell_book.get_spell_description(e.id) end)
                local pd, pdot, dd, weapon = adapt.parse_description(desc)
                if not st then
                    st = { n = 0, avg = 0, casts = 0 }
                    profile.spells[e.name] = st
                    learned[#learned + 1] = e.name
                else
                    -- A new rank: what was measured scales with the description.
                    local old, new = prior_of(st, level), prior_of({ pd = pd, weapon = weapon }, level)
                    if (st.n or 0) > 0 and old > 0 and new > 0 then
                        st.avg = st.avg * new / old
                    elseif new > 0 then
                        st.n = 0
                    end
                    learned[#learned + 1] = e.name .. " (new rank)"
                end
                st.id, st.role, st.pd, st.pdot, st.dd, st.weapon = e.id, e.role, pd, pdot, dd, weapon
                dirty = true
            end
        end
    end
    if #learned > 0 then
        core.log(string.format("[%s] Adaptive rotation learned: %s", PLUGIN, table.concat(learned, ", ")))
        adapt.save(true)
    end
end

function adapt.set_cast_time_fn(fn) ct_fn = fn end

-- ----------------------------------------------------------------------------
-- READING CASTS AND THEIR DAMAGE
-- ----------------------------------------------------------------------------
local function my_guid()
    if not ok_izi or type(izi) ~= "table" then return nil end
    local me = safe(izi.me)
    return me and safe(me.get_guid, me) or nil
end

--- core.register_on_spell_cast_callback: { spell_id, caster, target }.
function adapt.on_cast(data)
    if not profile or type(data) ~= "table" then return end
    local name = id_name[tonumber(data.spell_id) or -1]
    if not name then return end
    local caster = data.caster
    if not caster or safe(caster.get_guid, caster) ~= my_guid() then return end
    local st = profile.spells[name]
    if not st then return end
    st.casts = (st.casts or 0) + 1
    dirty = true
    local tg = data.target and safe(data.target.get_guid, data.target) or nil
    if not tg or st.role == "debuff" or (st.pdot or 0) > 0 then return end
    local ct = tonumber(safe(function() return core.spell_book.get_spell_cast_time(data.spell_id) end)) or 0
    if ct > 20 then ct = ct / 1000 end
    if #pending >= 8 then table.remove(pending, 1) end
    local t = now()
    pending[#pending + 1] = { name = name, guid = tg, t = t, till = t + ct + LAND_WINDOW }
end

local function swing_now(unit)
    if not auto_attack or not unit then return false end
    local last = tonumber(safe(function() return auto_attack:get_last_attack_core_time(unit) end))
    return last ~= nil and math.abs(now() - last) < SWING_GAP
end

local function record(name, dmg)
    local st = profile and profile.spells[name]
    if not st then return end
    local p = prior_of(st, profile.level)
    if p > 0 and dmg > 4 * p then dmg = 4 * p end
    if (st.n or 0) == 0 then st.avg = dmg else st.avg = st.avg + (dmg - st.avg) * ALPHA end
    st.n = math.min((st.n or 0) + 1, 999)
    dirty = true
end

--- Every frame of a fight (smart.combat): health drops of the target are
--- matched to the casts that caused them, and kills are timed.
function adapt.tick(player, target)
    if not profile then return end
    local t = now()
    for i = #pending, 1, -1 do
        if pending[i].till < t then table.remove(pending, i) end
    end
    local g = target and safe(target.get_guid, target) or nil
    if not g then
        hp_guid, hp_last = nil, nil
        return
    end
    local dead = safe(target.is_dead_or_ghost, target) == true
    -- Kill timing: from the first frame in combat with this target to its death.
    if fight.guid ~= g then
        fight.guid, fight.t = g, nil
    end
    if not fight.t and not dead and safe(player.is_in_combat, player) == true then fight.t = t end
    if dead and fight.t then
        local ttk = t - fight.t
        fight.t = false
        if ttk > 0.5 and ttk < 300 then
            profile.kills = (profile.kills or 0) + 1
            profile.ttk = ((profile.ttk or 0) <= 0) and ttk or (profile.ttk + (ttk - profile.ttk) * ALPHA)
            dirty = true
            if profile.kills % 10 == 0 then
                core.log(string.format("[%s] Adaptive rotation: %d kills, %.1f s a kill (%s).",
                    PLUGIN, profile.kills, profile.ttk, profile.order or "-"))
            end
        end
    end
    local hp = tonumber(safe(target.get_health, target))
    if not hp then return end
    if hp_guid ~= g then
        hp_guid, hp_last = g, hp
        return
    end
    local drop = (hp_last or hp) - hp
    hp_last = hp
    if drop <= 0 then return end
    local pet = safe(player.get_pet, player)
    local noisy = swing_now(player) or (pet and swing_now(pet)) or hp <= 0
    for i = 1, #pending do
        local pc = pending[i]
        if pc.guid == g then
            table.remove(pending, i)
            if not noisy then record(pc.name, drop) end
            break
        end
    end
    adapt.save(false)
end

-- ----------------------------------------------------------------------------
-- JUDGING
-- ----------------------------------------------------------------------------
local function cast_time(e)
    local v = ct_fn and tonumber(safe(ct_fn, e)) or nil
    return v or 0
end

local function mana_cost(id)
    local costs = safe(function() return core.spell_book.get_spell_costs(id) end)
    if type(costs) ~= "table" then return 0 end
    for i = 1, #costs do
        local k = costs[i]
        if type(k) == "table" and tonumber(k.cost_type) == 0 and tonumber(k.cost) then return k.cost end
    end
    return 0
end

--- Seconds the fight with `target` still has: time_to_die, else the
--- combat_forecast single-target forecast, else the learned kill time.
function adapt.fight_left(target)
    if target then
        local ttd = tonumber(safe(target.time_to_die, target))
        if ttd and ttd > 0 and ttd < 1e5 then return ttd end
        if forecast then
            local f = tonumber(safe(function() return forecast:get_forecast_single(target) end))
            if f and f > 0 and f < 1e5 then return f end
        end
    end
    local p = profile and profile.ttk or 0
    return p > 0 and p or 10
end

--- Damage `e` should do to `target`: measured, else from its description,
--- through health_prediction's speculate_damage (armor, resistances).
function adapt.damage(e, player, target, left)
    local st = profile and profile.spells[e.name]
    if not st then return nil end
    local direct = ((st.n or 0) >= MIN_SAMPLES and st.avg > 0) and st.avg or prior_of(st, profile.level)
    if direct > 0 and (st.n or 0) < MIN_SAMPLES and health_pred and player and target then
        local key = tostring(safe(target.get_guid, target)) .. ":" .. tostring(e.id)
        local c = spec_cache[key]
        local t = now()
        if not c or t - c.t > 2 then
            local v = tonumber(safe(function() return health_pred:speculate_damage(player, target, direct, e.id) end))
            c = { t = t, v = (v and v > 0) and v or direct }
            spec_cache[key] = c
        end
        direct = c.v
    end
    local dot = st.pdot or 0
    if dot > 0 and (st.dd or 0) > 0 then
        dot = dot * math.min(1, (left or adapt.fight_left(target)) / st.dd)
    end
    local total = direct + dot
    return total > 0 and total or nil
end

local function score(e, player, target, left, by_mana)
    local dmg = adapt.damage(e, player, target, left)
    if not dmg then return nil end
    if by_mana then
        local cost = mana_cost(e.id)
        if cost > 0 then return dmg / cost * 100 end
    end
    local tc = cast_time(e)
    if tc < GCD then tc = GCD end
    return dmg / tc
end

local reuse = {}
--- `bucket` re-ordered best first. Spells with no damage figure keep their
--- places (Shoot, Auto Shot); the others are sorted into the remaining ones.
function adapt.order(bucket, role, player, target, mana_pct)
    if not profile or not adapt.enabled() or type(bucket) ~= "table" or #bucket < 2 then return bucket end
    local left = adapt.fight_left(target)
    local by_mana = type(mana_pct) == "number" and mana_pct < LOW_MANA
    local slots, scored = {}, {}
    for i = 1, #bucket do
        local s = score(bucket[i], player, target, left, by_mana)
        if s then
            slots[#slots + 1] = i
            scored[#scored + 1] = { e = bucket[i], s = s, i = i }
        end
    end
    if #scored < 2 then return bucket end
    table.sort(scored, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        return a.i < b.i
    end)
    local out = reuse[bucket] or {}
    reuse[bucket] = out
    for i = 1, #bucket do out[i] = bucket[i] end
    for i = #out, #bucket + 1, -1 do out[i] = nil end
    for k = 1, #slots do out[slots[k]] = scored[k].e end
    if role == "damage" then
        local names = {}
        for k = 1, #scored do names[k] = scored[k].e.name end
        local o = table.concat(names, " > ")
        if o ~= last_order then
            last_order = o
            profile.order = o
            dirty = true
            trail("adaptive order: %s", o)
        end
    end
    return out
end

--- The spells of `entries` that kill `target` now, fastest cast first.
function adapt.killers(entries, player, target)
    local out = {}
    if not profile or not adapt.enabled() or not target then return out end
    local hp = tonumber(safe(target.get_health, target))
    if not hp or hp <= 0 then return out end
    for i = 1, #entries do
        local e = entries[i]
        local st = profile.spells[e.name]
        if st and (st.pdot or 0) == 0 then
            local dmg = adapt.damage(e, player, target, 0)
            if dmg and dmg * KILL_MARGIN >= hp then
                out[#out + 1] = { e = e, ct = cast_time(e), i = i }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.ct ~= b.ct then return a.ct < b.ct end
        return a.i < b.i
    end)
    for i = 1, #out do out[i] = out[i].e end
    return out
end

--- Is a DoT worth applying: the fight lasts at least half its duration.
function adapt.dot_worth(e, target)
    if not profile or not adapt.enabled() then return true end
    local st = profile.spells[e.name]
    local dur = st and st.dd or 0
    local need = dur > 0 and math.max(dur * 0.5, 3) or 4
    return adapt.fight_left(target) >= need
end

--- Is a cooldown worth using: combat_forecast's minimum fight length for it
--- (SHORT mode) is met, or without the module, the fight lasts 6 s more.
function adapt.cooldown_worth(e, target)
    if not adapt.enabled() then return true end
    if forecast then
        local en = forecast.enum
        local mode = type(en) == "table" and en.SHORT or nil
        if mode ~= nil then
            local min = tonumber(safe(function() return forecast:get_min_combat_length(mode, PLUGIN, e.name) end))
            if min then
                local v = safe(function() return forecast:is_valid_forecast_logic(min, target) end)
                if type(v) == "boolean" then return v end
            end
        end
    end
    return adapt.fight_left(target) >= 6
end

--- Will `target` be dead before a cast of `ct` seconds lands? From the
--- incoming damage health_prediction expects in that time.
function adapt.dies_first(target, ct)
    if not health_pred or not target or not adapt.enabled() then return false end
    local hp = tonumber(safe(target.get_health, target))
    if not hp or hp <= 0 then return false end
    local inc = tonumber(safe(function() return health_pred:get_incoming_damage(target, (ct or 0) + 0.25) end))
    return inc ~= nil and inc >= hp
end

--- Melee weaving: may a cast-time spell go out now without clipping the
--- next swing? Yes when not auto attacking, when it ends before the swing,
--- or right after a swing landed.
function adapt.swing_ok(player, ct)
    if not auto_attack or not player or (ct or 0) <= 0 or not adapt.enabled() then return true end
    if safe(function() return auto_attack:is_auto_attacking(player) end) ~= true then return true end
    local t = safe(core.time) or now()
    local nxt = tonumber(safe(function() return auto_attack:get_next_attack_core_time(player) end))
    local last = tonumber(safe(function() return auto_attack:get_last_attack_core_time(player) end))
    if not nxt or nxt <= t then return true end
    if nxt - t >= ct then return true end
    return last ~= nil and t - last < 0.4
end

-- ----------------------------------------------------------------------------
-- INSTALL (once per session; a reload only swaps the handler)
-- ----------------------------------------------------------------------------
_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}
local NS = _G.MasterFarmer_Grindbot

function adapt.install()
    NS.adapt_on_cast = adapt.on_cast
    if NS.adapt_cast_cb then return false end
    if type(core.register_on_spell_cast_callback) ~= "function" then return false end
    local ok = pcall(core.register_on_spell_cast_callback, function(data)
        local h = NS.adapt_on_cast
        if h then pcall(h, data) end
    end)
    NS.adapt_cast_cb = ok
    return ok
end

function adapt.uninstall()
    NS.adapt_on_cast = nil
    adapt.save(true)
end

-- Tests and the status line.
function adapt.profile() return profile end
function adapt._reset()
    profile, dirty, saved_t, id_name, pending = nil, false, -1e9, {}, {}
    hp_guid, hp_last, fight, spec_cache, last_order = nil, nil, { guid = nil, t = nil }, {}, ""
end
function adapt._libs(f, h, a) forecast, health_pred, auto_attack = f, h, a end

return adapt
