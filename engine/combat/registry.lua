-- ============================================================================
-- combat/registry.lua - WHICH class uses which verb, and WHEN.
-- ============================================================================
-- A rotation does not press keys, does not call Sentinel and does not call
-- movement_handler. It calls registry.add. The engine ticks the registry once
-- per update: registrations are tried in the order they were added, and the
-- first verb whose when(ctx) returns true - and whose start() accepts - is the
-- active move. Every other move is idle. When the active when() goes false,
-- combat/verbs.lua releases whatever key or walk that verb started, on that
-- same frame.
--
-- A new class, or a new trick on an existing class, is one registry.add with
-- an id, a class id from enums.class_id, a verb name that already exists and a
-- when(ctx). If the motion does not exist yet, one function is added to
-- verbs.lua and registered here. There is no third file, and no class is ever
-- special-cased inside close or orbit.
--
-- ctx is a plain table this file fills once per tick. when() reads those
-- fields; it never re-scans the object manager.
-- ============================================================================

local verbs = require("engine/combat/verbs")
local engine = require("engine/astar")

---@type enums
local enums = require("common/enums")
---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

local R = {}

local CLASS = enums.class_id

-- Spell id lists, as the rotations already carry them.
local FROST_NOVA_IDS = { 27088, 10230, 6131, 865, 122, 33395 }
local COLD_IDS       = { 27087, 10161, 10160, 10159, 8492, 120 }
local ROOTS_IDS      = { 26989, 9853, 9852, 5196, 5195, 1062, 339 }

-- GetShapeshiftFormID: 1 Cat, 5 Bear, 8 Dire Bear.
local DRUID_MELEE_FORMS = { [1] = true, [5] = true, [8] = true }

local SCAN_DEFAULT = 20
local MELEE_DANGER_DEFAULT = 8
local SPELL_MEMORY = 10.0

-- ---------------------------------------------------------------------------
-- registrations
-- ---------------------------------------------------------------------------
local entries = {}
local active = nil              -- the entry that is running
local settings_reader = nil
local target_reader = nil
local running = false
local hooked = false

--- Register a move. `verb` names a function in combat/verbs.lua.
--- opts = { id, class, verb, when, cfg }
function R.add(opts)
    if type(opts) ~= "table" then
        return false
    end
    if type(opts.id) ~= "string" or type(opts.verb) ~= "string" then
        return false
    end
    if type(verbs[opts.verb]) ~= "table" then
        pcall(core.log_error, "combat registry: no verb named " .. tostring(opts.verb))
        return false
    end
    if type(opts.when) ~= "function" then
        return false
    end
    for i = 1, #entries do
        if entries[i].id == opts.id then
            entries[i] = { id = opts.id, class = opts.class, verb = opts.verb,
                           when = opts.when, cfg = opts.cfg or {} }
            return true
        end
    end
    entries[#entries + 1] = { id = opts.id, class = opts.class, verb = opts.verb,
                              when = opts.when, cfg = opts.cfg or {} }
    return true
end

function R.remove(id)
    for i = 1, #entries do
        if entries[i].id == id then
            if active and active.id == id then
                R.release()
            end
            table.remove(entries, i)
            return true
        end
    end
    return false
end

function R.clear()
    R.release()
    for i = #entries, 1, -1 do
        entries[i] = nil
    end
end

function R.active_id()
    return active and active.id or nil
end

--- A product hands its own setting reader in: fn(name) -> boolean.
function R.set_settings_reader(fn)
    settings_reader = (type(fn) == "function") and fn or nil
end

--- A product may name the unit being fought. Without one the player's own
--- target is used.
function R.set_target_reader(fn)
    target_reader = (type(fn) == "function") and fn or nil
end

local function setting(name, default)
    if settings_reader then
        local ok, v = pcall(settings_reader, name)
        if ok and type(v) == "boolean" then
            return v
        end
    end
    return default == true
end

R.setting = setting

-- ---------------------------------------------------------------------------
-- last spell cast by the player
-- ---------------------------------------------------------------------------
local last_spell = { id = nil, t = -1e9 }

local function hook_spells()
    if hooked then
        return
    end
    hooked = true
    core.register_on_spell_cast_callback(function(data)
        if type(data) ~= "table" then
            return
        end
        local me = core.object_manager.get_local_player()
        if not me then
            return
        end
        local okv, valid = pcall(me.is_valid, me)
        if not okv or valid ~= true then
            return
        end
        local caster = data.caster
        if not caster or verbs.unit_guid(caster) ~= verbs.unit_guid(me) then
            return
        end
        if type(data.spell_id) == "number" then
            last_spell.id, last_spell.t = data.spell_id, engine.now()
        end
    end)
end

local function id_in(list, id)
    if not id then
        return false
    end
    for i = 1, #list do
        if list[i] == id then
            return true
        end
    end
    return false
end

R.id_in = id_in

--- Is one of `ids` on `unit` as a debuff?
local function debuff_up(unit, ids)
    if not unit then
        return false
    end
    local okv, valid = pcall(unit.is_valid, unit)
    if not okv or valid ~= true then
        return false
    end
    local ok, data = pcall(buff_manager.get_debuff_data, buff_manager, unit, ids)
    return ok and type(data) == "table" and data.is_active == true
end

R.debuff_up = debuff_up

-- ---------------------------------------------------------------------------
-- ctx
-- ---------------------------------------------------------------------------
local ctx = {}
local track = { guid = nil, distance = nil, t = 0 }

--- The range the close registration for this class was given. This is the
--- fallback: the live spell-book answer below is what normally decides.
local function close_range(class)
    for i = 1, #entries do
        local e = entries[i]
        if e.verb == "close" and (e.class == nil or e.class == class) then
            return tonumber(e.cfg and e.cfg.range)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cast range, read out of the game the way each rotation already reads its
-- own. Ranks are listed highest first, so the first known rank is the best one
-- the character has. No spell id is invented here: a class whose rotation
-- carries no filler list (the warlock) keeps the number its combat_range
-- returns, and the melee classes keep theirs.
-- ---------------------------------------------------------------------------
local FROSTBOLT  = { 27072, 27071, 25304, 10181, 10180, 10179, 8408, 8407, 8406, 7322, 837, 205, 116 }
local FIREBALL   = { 27070, 25306, 10151, 10150, 10149, 10148, 8402, 8401, 8400, 3140, 145, 143, 133 }
local MIND_FLAY  = { 25387, 18807, 17314, 17313, 17312, 17311, 15407 }
local WRATH      = { 26985, 26984, 9912, 8905, 6780, 5180, 5179, 5178, 5177, 5176 }
local LIGHTNING  = { 25449, 25448, 15208, 15207, 10392, 10391, 6041, 943, 915, 548, 529, 403 }
local AUTO_SHOT  = 75

-- hunter.lua's own numbers
local MELEE_BAND = 11               -- at or inside this the hunter fights in melee
local MELEE_CLOSE = 3               -- and closes to about this
local RANGED_MAX = 40
local DEAD_ZONE_FALLBACK = 8
local GUN_RANGE_FALLBACK = 35

local CASTER_FALLBACK = 30
local MELEE_FALLBACK = 5
local RANGE_TTL = 10.0              -- the game is asked at most this often

local range_cache = { t = -1e9, class = nil, value = nil }
local range_override = nil

--- A product that works its own engage range out (GUI sliders, a dead-zone
--- rule, a throw range) lends it here and it wins over the spell book.
--- fn(class, form, distance) returns yards, or nil to fall through.
function R.set_range_override(fn)
    range_override = (type(fn) == "function") and fn or nil
end

--- The maximum range of the highest rank of `ids` the character knows.
local function known_max_range(ids)
    for i = 1, #ids do
        local id = ids[i]
        local okk, known = pcall(core.spell_book.is_spell_known, id)
        if okk and known == true then
            local okr, reach = pcall(core.spell_book.get_spell_max_range, id)
            if okr and type(reach) == "number" and reach == reach and reach > 0 then
                return reach
            end
        end
    end
    return nil
end

R.known_max_range = known_max_range

--- Auto Shot's own min and max: the dead zone, and the weapon's real reach.
local function shot_ranges()
    local okn, mn = pcall(core.spell_book.get_spell_min_range, AUTO_SHOT)
    local okx, mx = pcall(core.spell_book.get_spell_max_range, AUTO_SHOT)
    if not okn or type(mn) ~= "number" or mn ~= mn or mn <= 0 or mn > 15 then
        mn = DEAD_ZONE_FALLBACK
    end
    if not okx or type(mx) ~= "number" or mx ~= mx or mx < 20 or mx > 50 then
        mx = GUN_RANGE_FALLBACK
    end
    return mn, mx
end

--- The hunter's dead zone: the 11-yard band, or the game's own if it is wider.
function R.dead_zone()
    local mn = shot_ranges()
    if mn > MELEE_BAND then
        return mn
    end
    return MELEE_BAND
end

--- The band this class wants to stand in, in yards. `form` and `distance` are
--- read for the two classes whose answer changes mid-fight.
local function resolve_range(class, form, distance)
    if class == CLASS.MAGE then
        -- mage.combat_range: Frostbolt, else Fireball
        return known_max_range(FROSTBOLT) or known_max_range(FIREBALL) or CASTER_FALLBACK
    end
    if class == CLASS.PRIEST then
        return known_max_range(MIND_FLAY) or CASTER_FALLBACK
    end
    if class == CLASS.DRUID then
        -- in bear or cat the druid is a melee class and its slider applies
        if DRUID_MELEE_FORMS[form] == true then
            return MELEE_FALLBACK
        end
        return known_max_range(WRATH) or CASTER_FALLBACK
    end
    if class == CLASS.SHAMAN then
        -- shaman.engage_range: Lightning Bolt's reach less a yard, floor 30
        local reach = known_max_range(LIGHTNING)
        if type(reach) == "number" then
            reach = reach - 1
        end
        if type(reach) ~= "number" or reach < 8 then
            reach = CASTER_FALLBACK
        end
        return reach
    end
    if class == CLASS.HUNTER then
        -- hunter.engage_range: inside the dead zone it fights in melee at
        -- MELEE_CLOSE; outside, the gun's reach less a yard, capped at
        -- RANGED_MAX and floored at the dead zone plus 2.
        local mn, mx = shot_ranges()
        local dead = (mn > MELEE_BAND) and mn or MELEE_BAND
        if type(distance) == "number" and distance <= dead then
            return MELEE_CLOSE
        end
        local want = mx - 1
        if want > RANGED_MAX then
            want = RANGED_MAX
        end
        local floor = dead + 2
        if want < floor then
            want = floor
        end
        return want
    end
    -- The warlock's combat_range returns 30 flat and its rotation carries no
    -- filler list, so no id is guessed for it. Rogue, warrior and paladin are
    -- melee: nil here keeps the registered cfg.range.
    if class == CLASS.WARLOCK then
        return CASTER_FALLBACK
    end
    return nil
end

--- Cached per class for RANGE_TTL, except the two answers that can change
--- inside that window - a druid shifting form, a hunter crossing the dead
--- zone - which are resolved every tick.
local function cast_range(class, form, distance, t)
    if range_override then
        local ok, yards = pcall(range_override, class, form, distance)
        if ok and type(yards) == "number" and yards == yards and yards > 0 then
            return yards
        end
    end
    if class == CLASS.HUNTER or class == CLASS.DRUID then
        return resolve_range(class, form, distance)
    end
    if range_cache.class == class and (t - range_cache.t) < RANGE_TTL then
        return range_cache.value
    end
    local value = resolve_range(class, form, distance)
    range_cache.class, range_cache.t, range_cache.value = class, t, value
    return value
end

R.cast_range = cast_range

local function health_pct(unit)
    local okh, hp = pcall(unit.get_health, unit)
    local okm, max = pcall(unit.get_max_health, unit)
    if okh and okm and type(hp) == "number" and type(max) == "number" and max > 0 then
        return hp / max * 100
    end
    return 100
end

R.health_pct = health_pct

--- Enemies within `yards` of the player, read once per tick.
local function scan_enemies(me, from, yards)
    local out = {}
    local ok, list = pcall(core.object_manager.get_visible_objects)
    if not ok or type(list) ~= "table" then
        return out
    end
    local reach = yards * yards
    for i = 1, #list do
        local o = list[i]
        local okv, valid = pcall(o.is_valid, o)
        if okv and valid == true then
            local oku, unit = pcall(o.is_unit, o)
            local okd, dead = pcall(o.is_dead, o)
            if oku and unit == true and not (okd and dead == true) then
                local oke, enemy = pcall(o.is_enemy_with, o, me)
                if oke and enemy == true then
                    local okp, p = pcall(o.get_position, o)
                    if okp and p and type(p.x) == "number" then
                        local dx, dy, dz = p.x - from.x, p.y - from.y, p.z - from.z
                        if (dx * dx + dy * dy + dz * dz) <= reach then
                            out[#out + 1] = o
                        end
                    end
                end
            end
        end
    end
    return out
end

local function pet_alive(me)
    local ok, pet = pcall(core.object_manager.get_object_from_guid, "pet")
    if not ok or not pet then
        return false
    end
    local okv, valid = pcall(pet.is_valid, pet)
    if not okv or valid ~= true then
        return false
    end
    local okd, dead = pcall(pet.is_dead, pet)
    if okd and dead == true then
        return false
    end
    local oko, owner = pcall(pet.get_owner, pet)
    if oko and owner then
        return verbs.unit_guid(owner) == verbs.unit_guid(me)
    end
    return true
end

local function build_ctx(me, t)
    local from = verbs.unit_pos(me)
    if not from then
        return nil
    end
    local target = nil
    if target_reader then
        local okt, unit = pcall(target_reader)
        if okt then
            target = unit
        end
    end
    if target == nil then
        local okt, unit = pcall(me.get_target, me)
        if okt then
            target = unit
        end
    end
    local tpos = verbs.unit_pos(target)
    if not tpos then
        target = nil
    end

    local okc, class = pcall(me.get_class, me)
    ctx.class = okc and class or nil
    ctx.player = me
    ctx.target = target

    local distance = nil
    if tpos then
        local dx, dy, dz = tpos.x - from.x, tpos.y - from.y, tpos.z - from.z
        distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    ctx.distance = distance

    -- a product's combat profile lends its two numbers through R.melee_danger
    -- / R.melee_safe; a class row's own cfg.melee_safe still wins over them
    local danger = tonumber(R.melee_danger) or MELEE_DANGER_DEFAULT
    ctx.melee_safe = tonumber(R.melee_safe) or nil
    ctx.enemies = scan_enemies(me, from, math.max(danger, verbs.FLEE_YD, SCAN_DEFAULT))
    local count = 0
    for i = 1, #ctx.enemies do
        local p = verbs.unit_pos(ctx.enemies[i])
        if p then
            local dx, dy = p.x - from.x, p.y - from.y
            if math.sqrt(dx * dx + dy * dy) <= danger then
                count = count + 1
            end
        end
    end
    ctx.melee_count = count

    -- approaching: the target is moving and the gap is closing
    local guid = verbs.unit_guid(target)
    ctx.approaching = false
    if guid and distance then
        if track.guid == guid and track.distance and (t - track.t) > 0.1 then
            local okm, moving = pcall(target.is_moving, target)
            ctx.approaching = (okm and moving == true) and distance < (track.distance - 0.2) or false
        end
        if track.guid ~= guid or (t - track.t) > 0.25 then
            track.guid, track.distance, track.t = guid, distance, t
        end
    else
        track.guid, track.distance = nil, nil
    end

    -- slowed: moving under its own maximum
    ctx.slowed = false
    if target then
        local oks, speed = pcall(target.get_movement_speed, target)
        local okx, best = pcall(target.get_movement_speed_max, target)
        if oks and okx and type(speed) == "number" and type(best) == "number" and best > 0 then
            ctx.slowed = speed > 0.1 and speed < (best * 0.85)
        end
    end

    local okcast, casting = pcall(me.is_casting_spell, me)
    local okchan, channel = pcall(me.is_channelling_spell, me)
    ctx.casting = (okcast and casting == true) or (okchan and channel == true)

    ctx.last_spell_id = last_spell.id
    ctx.last_spell_age = t - last_spell.t
    if ctx.last_spell_age > SPELL_MEMORY then
        ctx.last_spell_id = nil
    end

    ctx.health_pct = health_pct(me)

    ctx.behind = false
    if target and tpos then
        local okr, r = pcall(target.get_rotation, target)
        if okr and type(r) == "number" and r == r then
            local ax = math.atan2(from.y - tpos.y, from.x - tpos.x) - r
            while ax > math.pi do ax = ax - 2 * math.pi end
            while ax < -math.pi do ax = ax + 2 * math.pi end
            ctx.behind = math.abs(ax) > (math.pi * 0.666)
        end
    end

    ctx.pet_alive = pet_alive(me)

    local oksw, swimming = pcall(me.is_swimming, me)
    ctx.swimming = oksw and swimming == true

    local okf, form = pcall(core.spell_book.get_shapeshift_form_id)
    ctx.form = okf and form or nil

    local oki, inside = pcall(me.is_indoors, me)
    ctx.indoors = oki and inside == true

    -- the band this class wants, read out of the spell book; the registered
    -- cfg.range is the fallback for when the game has no answer
    ctx.cast_range = cast_range(ctx.class, ctx.form, distance, t) or close_range(ctx.class)

    -- in_position is that band, asked as a plain question so a verb gated on
    -- it works on its first frame too
    ctx.in_position = verbs.in_band(ctx, ctx.cast_range)

    return ctx
end

R.ctx = function()
    return ctx
end

-- ---------------------------------------------------------------------------
-- the tick
-- ---------------------------------------------------------------------------
function R.release()
    if active then
        local verb = verbs[active.verb]
        if verb and type(verb.stop) == "function" then
            pcall(verb.stop)
        end
        active = nil
    end
    verbs.release_all()
end

--- One decision per engine update. The registrations are scanned from the top
--- every tick: the first one whose class matches, whose when(ctx) is true and
--- whose verb accepts is the active move, and every other move is idle. A
--- higher row that comes true preempts the active one, whose keys or walk are
--- released on this same frame.
function R.tick()
    if not running then
        return nil
    end
    hook_spells()
    local me = core.object_manager.get_local_player()
    if not me then
        R.release()
        return nil
    end
    local okv, valid = pcall(me.is_valid, me)
    if not okv or valid ~= true then
        R.release()
        return nil
    end
    local t = engine.now()
    local c = build_ctx(me, t)
    if not c then
        R.release()
        return nil
    end

    -- no verb runs while swimming: just attack, kill and loot
    if c.swimming then
        R.release()
        return nil
    end

    local finished = nil            -- a verb that ended on this frame does not restart on it
    for i = 1, #entries do
        local entry = entries[i]
        if entry ~= finished and (entry.class == nil or entry.class == c.class) then
            local ok, want = pcall(entry.when, c)
            if ok and want == true then
                local verb = verbs[entry.verb]
                if active == entry then
                    local okt, alive = pcall(verb.tick, c, entry.cfg)
                    if okt and alive ~= false then
                        return entry.id
                    end
                    -- the move is over: release it and let a lower row have the frame
                    R.release()
                    finished = entry
                else
                    -- a higher row preempts whatever was running
                    if active then
                        R.release()
                    end
                    local started, accepted = pcall(verb.start, c, entry.cfg)
                    if started and accepted ~= false then
                        active = entry
                        return entry.id
                    end
                    -- start() refused (a blink into a wall, a walled strafe):
                    -- the next registration gets its turn on this same frame
                end
            end
        end
    end
    if active then
        R.release()
    end
    return nil
end

function R.start()
    running = true
    engine.ensure_engine()
    hook_spells()
end

function R.stop()
    running = false
    R.release()
end

function R.is_running()
    return running == true
end

-- ===========================================================================
-- CLASS REGISTRATIONS
-- ===========================================================================
-- Each when() body is the class's existing combat profile, moved here. A class
-- whose should_retreat returns false gets no backoff and no kite.
-- ---------------------------------------------------------------------------

local function has_target(c)
    return c.target ~= nil and c.distance ~= nil
end

--- The shared flee gate: FLEE_HP % health or less with FLEE_N or more enemies
--- inside FLEE_YD yards. It outranks everything else for the class it is on.
local function overwhelmed(c)
    if (c.health_pct or 100) > verbs.FLEE_HP then
        return false
    end
    local n = 0
    local from = verbs.unit_pos(c.player)
    if not from then
        return false
    end
    for i = 1, #(c.enemies or {}) do
        local p = verbs.unit_pos(c.enemies[i])
        if p then
            local dx, dy = p.x - from.x, p.y - from.y
            if math.sqrt(dx * dx + dy * dy) <= verbs.FLEE_YD then
                n = n + 1
            end
        end
    end
    return n >= verbs.FLEE_N
end

R.overwhelmed = overwhelmed

--- Another unit stacked on the character.
local function stacked(c)
    local from = verbs.unit_pos(c.player)
    if not from then
        return false
    end
    for i = 1, #(c.enemies or {}) do
        local p = verbs.unit_pos(c.enemies[i])
        if p then
            local dx, dy = p.x - from.x, p.y - from.y
            if math.sqrt(dx * dx + dy * dy) < verbs.STACKED_YD then
                return true
            end
        end
    end
    return false
end

function R.register_defaults()
    -- Flee and unstack are not class tricks: they belong to whoever is in
    -- trouble, and they are tried before any class move.
    R.add({ id = "any:flee", class = nil, verb = "flee", when = function(c)
        if verbs.fleeing() then
            return true
        end
        return overwhelmed(c)
    end })

    R.add({ id = "any:unstack", class = nil, verb = "unstack", when = function(c)
        if verbs.backpedaling() then
            return true
        end
        return stacked(c)
    end })

    -- ---------------------------------------------------------------- mage
    -- melee_danger 8, melee_safe 12.
    R.add({ id = "mage:blink_away", class = CLASS.MAGE, verb = "blink_away",
        when = function(c)
            if not has_target(c) then
                return false
            end
            if not setting("blink_away", false) then
                return false
            end
            return c.melee_count >= 1 and c.distance <= 5
        end })

    R.add({ id = "mage:backoff", class = CLASS.MAGE, verb = "backoff",
        cfg = { melee_safe = 12 },
        when = function(c)
            if not has_target(c) then
                return false
            end
            -- nothing is actually on us: stand and cast
            if c.melee_count < 1 and c.distance > 8 then
                return false
            end
            -- the target is held: this is the window to walk out
            if R.debuff_up(c.target, FROST_NOVA_IDS) then
                return true
            end
            -- a slowed, held enemy still walking at us inside 8 yd
            if c.approaching and c.slowed and not c.casting and c.distance <= 8 then
                return true
            end
            -- Cone of Cold or Frost Nova landed within the last 2 s
            if c.last_spell_age and c.last_spell_age <= 2.0 then
                if id_in(COLD_IDS, c.last_spell_id) then
                    return true
                end
                if id_in(FROST_NOVA_IDS, c.last_spell_id) then
                    return true
                end
            end
            return false
        end })

    -- cfg.range is the fallback only: ctx.cast_range carries Frostbolt's (or
    -- Fireball's) real reach, read out of the spell book.
    R.add({ id = "mage:close", class = CLASS.MAGE, verb = "close",
        cfg = { range = 30 },
        when = has_target })
    R.add({ id = "mage:face", class = CLASS.MAGE, verb = "face", when = has_target })

    -- -------------------------------------------------------------- priest
    -- should_retreat returns false: no snare, and under 35% health the profile
    -- refuses to walk. close and face only - no backoff.
    -- fallback only: ctx.cast_range carries Mind Flay's real reach
    R.add({ id = "priest:close", class = CLASS.PRIEST, verb = "close",
        cfg = { range = 30 }, when = has_target })
    R.add({ id = "priest:face", class = CLASS.PRIEST, verb = "face", when = has_target })

    -- ------------------------------------------------------------- warlock
    -- melee_danger 8, melee_safe 12. The pet tanking is not a retreat.
    R.add({ id = "warlock:backoff", class = CLASS.WARLOCK, verb = "backoff",
        cfg = { melee_safe = 12 },
        when = function(c)
            if not has_target(c) then
                return false
            end
            if c.melee_count < 1 then
                return false
            end
            return c.pet_alive ~= true
        end })
    -- 30 flat, as warlock.combat_range returns: its rotation carries no
    -- filler list, so no spell id is guessed to read a range from
    R.add({ id = "warlock:close", class = CLASS.WARLOCK, verb = "close",
        cfg = { range = 30 }, when = has_target })
    R.add({ id = "warlock:face", class = CLASS.WARLOCK, verb = "face", when = has_target })

    -- -------------------------------------------------------------- hunter
    -- should_retreat returns false: inside the dead zone the hunter closes to
    -- about 3 yards and fights in melee, so no dead-zone kite is registered.
    -- back_jump is the pet-aggro option only.
    R.add({ id = "hunter:back_jump", class = CLASS.HUNTER, verb = "back_jump",
        when = function(c)
            if not has_target(c) then
                return false
            end
            if not setting("hunter_pet_aggro", false) then
                return false
            end
            if c.pet_alive ~= true then
                return false
            end
            return c.distance <= 5
        end })
    -- fallback only: ctx.cast_range carries the gun's reach less a yard, or
    -- MELEE_CLOSE once the target is inside the dead zone
    R.add({ id = "hunter:close", class = CLASS.HUNTER, verb = "close",
        cfg = { range = 34 }, when = has_target })
    R.add({ id = "hunter:face", class = CLASS.HUNTER, verb = "face", when = has_target })

    -- --------------------------------------------------------------- rogue
    -- should_retreat returns false. Orbit yields to step_behind while the
    -- stealth opener or the Gouge window is open.
    R.add({ id = "rogue:step_behind", class = CLASS.ROGUE, verb = "step_behind",
        cfg = { reach = 5 },
        when = function(c)
            if not has_target(c) then
                return false
            end
            if c.in_position ~= true then
                return false
            end
            return R.wants_behind(c) == true
        end })
    R.add({ id = "rogue:orbit", class = CLASS.ROGUE, verb = "orbit",
        when = function(c)
            if not has_target(c) then
                return false
            end
            if not setting("strafe_combat", false) then
                return false
            end
            return c.in_position == true
        end })
    R.add({ id = "rogue:close", class = CLASS.ROGUE, verb = "close",
        cfg = { range = 5 }, when = has_target })
    R.add({ id = "rogue:face", class = CLASS.ROGUE, verb = "face", when = has_target })

    -- ------------------------------------------------------------- warrior
    -- should_retreat returns false. The same orbit verb as the rogue, behind
    -- the warrior's own "Strafe in Combat" box. No second strafe function.
    R.add({ id = "warrior:orbit", class = CLASS.WARRIOR, verb = "orbit",
        when = function(c)
            if not has_target(c) then
                return false
            end
            if not setting("strafe_combat_warrior", false) then
                return false
            end
            return c.in_position == true
        end })
    R.add({ id = "warrior:close", class = CLASS.WARRIOR, verb = "close",
        cfg = { range = 5 }, when = has_target })
    R.add({ id = "warrior:face", class = CLASS.WARRIOR, verb = "face", when = has_target })

    -- ------------------------------------------------------------- paladin
    -- should_retreat returns false, scan 20. close and face, no backoff, no orbit.
    R.add({ id = "paladin:close", class = CLASS.PALADIN, verb = "close",
        cfg = { range = 5 }, when = has_target })
    R.add({ id = "paladin:face", class = CLASS.PALADIN, verb = "face", when = has_target })

    -- --------------------------------------------------------------- druid
    -- Melee forms (bear and cat) use the warrior pattern: close, face, no
    -- backoff. Caster form: melee_danger 8, melee_safe 14, and the backoff is
    -- the Entangling Roots window only.
    R.add({ id = "druid:backoff", class = CLASS.DRUID, verb = "backoff",
        cfg = { melee_safe = 14 },
        when = function(c)
            if not has_target(c) then
                return false
            end
            if DRUID_MELEE_FORMS[c.form] == true then
                return false
            end
            if c.melee_count < 1 and c.distance > 8 then
                return false
            end
            return R.debuff_up(c.target, ROOTS_IDS)
        end })
    -- fallback only: ctx.cast_range carries Wrath's real reach in caster
    -- form, and the melee distance in bear or cat
    R.add({ id = "druid:close", class = CLASS.DRUID, verb = "close",
        when = has_target,
        cfg = { range = 30 } })
    R.add({ id = "druid:face", class = CLASS.DRUID, verb = "face", when = has_target })

    -- -------------------------------------------------------------- shaman
    -- Enhancement is the warrior pattern without orbit. Elemental's
    -- should_retreat returns false, so there is no Elemental kite here.
    -- fallback only: ctx.cast_range carries Lightning Bolt's reach less a yard
    R.add({ id = "shaman:close", class = CLASS.SHAMAN, verb = "close",
        cfg = { range = 30 }, when = has_target })
    R.add({ id = "shaman:face", class = CLASS.SHAMAN, verb = "face", when = has_target })
end

--- The rogue's step-behind window: a product overrides this with its own
--- smart.rogue_wants_behind. Without one it is the target's rear arc being
--- wanted and not yet reached.
local wants_behind_reader = nil

function R.set_wants_behind_reader(fn)
    wants_behind_reader = (type(fn) == "function") and fn or nil
end

function R.wants_behind(c)
    if wants_behind_reader then
        local ok, v = pcall(wants_behind_reader, c.player, c.target)
        if ok then
            return v == true
        end
    end
    return false
end

--- A druid melee form, for a product that wants the same answer this file uses.
function R.druid_is_melee(form)
    return DRUID_MELEE_FORMS[form] == true
end

-- The class rows are live the moment this file loads. A product replaces one
-- by calling R.add with the same id, or drops it with R.remove.
R.register_defaults()

R.FROST_NOVA_IDS = FROST_NOVA_IDS
R.COLD_IDS = COLD_IDS
R.ROOTS_IDS = ROOTS_IDS

return R
