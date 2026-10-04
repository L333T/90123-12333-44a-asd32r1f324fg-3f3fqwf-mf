-- ============================================================================
-- Master Farmer - Grindbot
-- resting.lua - the eat / drink implementation every rotation drives
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.232.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY THIS IS SHARED AND NOT COPIED NINE TIMES
--   Each class owns its resting decision - when to sit down, and at what
--   percentage - but the machinery underneath is identical for all of them and
--   has been wrong three times already: the aura-latency double-drink (1.4.6),
--   the use counter that never reset (1.4.8), and the global cooldown refusing
--   consumables silently (1.4.9). Nine copies means nine places for the next
--   one to hide, so the rules live here and the rotations supply the policy:
--
--       function mage.rest(player)
--           return resting.tick(player, { eat_pct = 30, drink_pct = 30 })
--       end
--
--   A class that wants to rest earlier, later, or not at all changes its own
--   numbers; nothing else has to move.
--
-- WHAT IT GUARANTEES  (carried over unchanged, each one earned)
--   * one consumable at a time, with a 5s commit window covering the delay
--     between using an item and its aura appearing
--   * separate food and drink timers, because both auras run at once in TBC
--   * a per-rest use cap that RE-ARMS when the rest ends
--   * skip_gcd on the item use, because food and drink do not use the global
--     cooldown but use_self_safe gates on it by default
--   * every refusal is reported once per rest instead of stalling in silence
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local consumables = require("data/consumables")
local gui = require("gui")
-- rotation is required LAZILY and deliberately.
--
-- rotation.lua requires the nine class rotations, each of which requires this
-- module, so a top-level require here would close the loop: Lua only records a
-- module in package.loaded after its chunk returns, so a circular require
-- re-enters the half-built chunk instead of getting the finished table.
local rotation_mod = nil

local function get_rotation()
    if rotation_mod then
        return rotation_mod
    end
    local ok, mod = pcall(require, "rotation")
    if ok and type(mod) == "table" then
        rotation_mod = mod
    end
    return rotation_mod
end

--- The class's preferred consumable ids, or nil when it has no opinion.
local function preferred(which, player)
    local rotation = get_rotation()
    if not rotation or type(rotation[which]) ~= "function" then
        return nil
    end
    local ok, ids = pcall(rotation[which], player)
    if ok then
        return ids
    end
    return nil
end
local movement = require("movement")
local state = require("state")

local resting_mod = {}

local FOOD_AURAS = consumables.FOOD_AURA_IDS
local DRINK_AURAS = consumables.DRINK_AURA_IDS
local FOOD_ITEM_RANK = consumables.FOOD_ITEM_IDS
local WATER_ITEM_RANK = consumables.WATER_ITEM_IDS

-- Rest at or below this, unless the rotation says otherwise.
local REST_DEFAULT = 30
local REST_DONE = 100
local REGEN_DONE = 80          -- 2.139.0: no food / water - wait for this much HP and MP
local regen_wait = false
local water_stay_logged = false
local REST_TOPUP = 95         -- 2.99.0: the other resource is topped up in the same rest below this

-- Seconds a use is committed for before another of the same kind is
-- considered - eat or drink for this long before reaching for another item.
--
-- It also covers the delay between using an item and its aura becoming
-- visible; that alone wanted 5s, because a 3s window still double-consumed
-- when the aura took 4.5s to register. Fifteen is the eating time asked for,
-- and it subsumes the aura delay.
--
-- This only bites when NO aura is up: a meal that is actually ticking is left
-- alone by the first check in consume_one however long it runs.
local USE_COMMIT = 15.0
local JUST_USED = 3.0          -- 2.110.0: seconds an item use counts as eating / drinking
-- Worst-case bound per rest session if aura detection is broken entirely.
local MAX_USES = 8

-- How close a hostile mob may be before sitting down is a bad idea.
--
-- Being out of combat is not the same as being safe. A mob that has not
-- aggroed yet is still standing there, and eating in front of it means
-- taking the first hit sitting down, at the health that made the bot stop to
-- eat in the first place. The rest waits until nothing hostile is inside
-- this radius.
local REST_CLEAR_YARDS = 10

-- Gates use_self_safe applies by default, and why one of them is turned off.
--
-- use_self_safe refuses while the global cooldown is running. Food and drink
-- do not trigger or respect the GCD in TBC, so that gate is simply wrong for a
-- consumable - and it bites constantly, because a rest is entered the moment a
-- kill finishes, while the rotation's last cast still has the GCD spinning.
--
-- The other gates (usable, cooldown, moving, mounted, casting, channelling)
-- are left on: halt_for_rest has already stopped the bot, and they are real.
local USE_OPTS = { skip_gcd = true }

local food_state  = { last = -1e9, uses = 0, pending = false, warned = false }
local drink_state = { last = -1e9, uses = 0, pending = false, warned = false }
local rest_eat = false
local rest_drink = false
local resting = false
local miss_logged = false
local item_by_id = {}
local path_runner_mod = nil

-- ----------------------------------------------------------------------------
-- DIAGNOSTIC
-- ----------------------------------------------------------------------------
-- Every gate below this point can stop a rest, and most of them were silent.
-- mfg_rest_debug names the one that is actually holding, once per second and
-- only when it changes, so a stalled rest can be read straight off the log
-- instead of guessed at.
local dbg_last_msg, dbg_last_t = nil, -1e9

local function rest_debug(fmt, ...)
    if gui.is_on("rest_debug") ~= true then
        return
    end
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    do
        local ok_d, dbg = pcall(require, "debuglog")
        if ok_d and dbg and type(dbg.line) == "function" then
            dbg.line("rest", "%s", tostring(msg))
        end
    end
    local t = 0
    local ok, now = pcall(function() return izi.now() end)
    if ok and type(now) == "number" then t = now end
    if msg == dbg_last_msg and (t - dbg_last_t) < 1.0 then
        return
    end
    dbg_last_msg, dbg_last_t = msg, t
    core.log("[Master Farmer - Grindbot] rest: " .. msg)
end

-- The session log (2.67.0). rest_debug only reaches the in-game console,
-- and only with the Rest debug box ticked, so a rest that never started - no
-- water in the bags, a threat nearby, the client refusing the item - left
-- nothing in scripts_log. These go to MASTER_FARMER_ERRORS as TRAIL lines
-- (written only when they change), and the item use itself is probed, so an
-- armed flight recorder names it if the game dies there.
local errorlog_mod = nil
local function elog()
    if errorlog_mod == nil then
        local ok, m = pcall(require, "errorlog")
        errorlog_mod = (ok and type(m) == "table") and m or false
    end
    return errorlog_mod or nil
end

local function rtrail(fmt, ...)
    local el = elog()
    if el and type(el.trail) == "function" then
        pcall(el.trail, "rest", fmt, ...)
    end
end

local function rprobe(tag)
    local el = elog()
    if el and type(el.probe) == "function" then
        pcall(el.probe, tag)
    end
end

local function pcall_item(id)
    local ok, item = pcall(function() return izi.item(id) end)
    if ok then return item end
    return nil
end

local function item_of(id)
    if type(id) ~= "number" then
        return nil
    end
    local cached = item_by_id[id]
    if cached then
        return cached
    end
    local item = pcall_item(id)
    if item then
        item_by_id[id] = item
    end
    return item
end

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- Prewarm the item cache. Every call is guarded: this runs at module load over
-- ~250 ids, and an unguarded throw on any one of them would abort the whole
-- chunk. main.lua bails out entirely when `healing` is missing, so one bad id
-- would take the whole bot down rather than just one food.
local function prewarm(list)
    for i = 1, #list do
        local id = list[i]
        local item = safe(function() return izi.item(id) end)
        if item then
            item_by_id[id] = item
        end
    end
end
prewarm(FOOD_ITEM_RANK)
prewarm(WATER_ITEM_RANK)

local function as_percent(value, current, maximum)
    if type(value) == "number" then
        if value >= 0 and value <= 1.5 then
            return value * 100
        end
        return value
    end
    if type(current) == "number" and type(maximum) == "number" and maximum > 0 then
        return (current / maximum) * 100
    end
    return 100
end

local function health_pct(player)
    local pct = safe(function() return player:get_health_percentage() end)
    local cur = safe(function() return player:get_health() end)
    local maxh = safe(function() return player:max_health() end)
    return as_percent(pct, cur, maxh)
end

local power = require("power")

local function mana_pct(player)
    -- power.lua (2.202.0): izi mana_* first, native get_power / get_max_power (mana 0) when
    -- they read nothing - on WoW Forever a Mage read as having no mana and never drank.
    return power.mana_pct(player)
end

local function has_any_aura(player, ids)
    if not player then
        return false
    end
    if safe(function() return player:has_buff(ids) end) == true then
        return true
    end
    if safe(function() return player:has_aura(ids) end) == true then
        return true
    end
    return false
end

local function ranked_ids(base, extra)
    local seen = {}
    local out = {}
    local function add(id)
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    -- Class preference first (2.173.0): a mage's conjured water and food are
    -- what the rest drinks and eats while any are in the bags.
    if type(extra) == "table" then
        for i = 1, #extra do
            add(extra[i])
        end
    end
    for i = 1, #base do
        add(base[i])
    end
    return out
end

-- Ranked lists cached per class preference (2.145.0): they were rebuilt -
-- four new tables - on every 0.1 s rest check.
local ranked_cache = {}

local function cached_ranked(key, base, extra)
    local c = ranked_cache[key]
    if c and c.extra == extra and c.n == (type(extra) == "table" and #extra or 0) then
        return c.list
    end
    local list = ranked_ids(base, extra)
    ranked_cache[key] = { extra = extra, n = type(extra) == "table" and #extra or 0, list = list }
    return list
end

-- Bag food / water the curated lists miss (2.149.0, bags.food_water): a
-- quest reward or a new drop is eaten after every ranked item, instead of the
-- rest calling it "no usable food" and sending the bot to a vendor.
local bags = require("bags")
local extra_cache = {}

local function with_bag_extras(key, list, extras)
    if #extras == 0 then return list end
    local sig = table.concat(extras, ",")
    local c = extra_cache[key]
    if c and c.base == list and c.sig == sig then return c.list end
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    for i = 1, #extras do out[#out + 1] = extras[i] end
    extra_cache[key] = { base = list, sig = sig, list = out }
    return out
end

local function food_ids(player)
    local list = cached_ranked("food", FOOD_ITEM_RANK, preferred("preferred_food_ids", player))
    local ef = bags.extra_food_water(player)
    return with_bag_extras("food", list, ef)
end

local function water_ids(player)
    local list = cached_ranked("water", WATER_ITEM_RANK, preferred("preferred_drink_ids", player))
    local _, ew = bags.extra_food_water(player)
    return with_bag_extras("water", list, ew)
end

-- WHAT IS IN THE BAGS (2.231.0). has_usable walked every known food / water
-- id (~380) and asked izi.item(id):count() for each - a bag scan per id. With
-- no food in the bags nothing ended the loop early, and the rest tick asks up
-- to four times: after every kill at low health, 30-40 ms and 4-6 MB a
-- check, every 2 s (SPIKE u:healing 60-76 ms, heap +8.7 MB, 19:24 and 19:30
-- sessions). Now the bags are read once per PRESENT_TTL and only ids
-- actually carried are asked about. nil = bags unreadable: the old full walk.
local PRESENT_TTL = 1.0
local present = { t = -1e9, set = nil }

local function bag_present()
    if not bags.readable() then return nil end
    local now = izi.now()
    if present.set and (now - present.t) < PRESENT_TTL then return present.set end
    local me = nil
    pcall(function() me = izi.me() end)
    local set = {}
    local list = bags.list(me)
    for i = 1, #list do
        local id = list[i].item_id
        if id then set[id] = true end
    end
    present.t, present.set = now, set
    return set
end

local function present_reset()
    present.t = -1e9
end

local function has_usable(ids)
    if type(ids) ~= "table" then
        return false
    end
    local carried = bag_present()
    for i = 1, #ids do
        local item = (carried == nil or carried[ids[i]]) and item_of(ids[i]) or nil
        if item then
            local count = safe(function() return item:count() end) or 0
            local ready = safe(function() return item:cooldown_up() end) == true
            if count > 0 and ready then
                return true
            end
        end
    end
    return false
end

--- Use the best consumable in `ids`.
---
--- Returns (true) on success, or (false, reason) so the caller can say what
--- went wrong. Before 1.4.9 a refused use returned a bare false and the bot sat
--- in the rest state consuming nothing and logging nothing, for ever - which is
--- indistinguishable from "eating and drinking do not run at all".
local function use_first(ids)
    if type(ids) ~= "table" then
        return false, "no id list"
    end
    -- The first one carried wins, because the lists are ordered best first.
    --
    -- 2.6.0 sorted by a level table instead, which was the right fix for the
    -- list as it stood then: it was ordered by item id, so a character with
    -- Tough Jerky and Roasted Quail could sit down to the jerky. The lists in
    -- data/consumables are now genuinely best first and cover drops and quest
    -- food too, so position IS the ranking. A second, sparser ranking on top
    -- of it could only disagree with it - an item missing from the level
    -- table scored zero and lost to a level 1 vendor roll.
    local held = 0
    local refused = nil
    local carried = bag_present()
    for i = 1, #ids do
        local item = (carried == nil or carried[ids[i]]) and item_of(ids[i]) or nil
        if item then
            local count = safe(function() return item:count() end) or 0
            local ready = safe(function() return item:cooldown_up() end) == true
            if count > 0 and ready then
                held = held + 1
                rprobe("rest:use " .. tostring(ids[i]))
                local ok = safe(function()
                    return item:use_self_safe("Consume", USE_OPTS)
                end)
                if ok ~= true then
                    -- The guarded call still said no. By this point the bot is
                    -- stationary, unmounted, out of combat and not swimming, so
                    -- the remaining guards have nothing left to protect - try
                    -- the plain use rather than stall the whole rest.
                    ok = safe(function() return item:use_self("Consume") end)
                end
                rprobe("rest:used")
                if ok == true then
                    present_reset()          -- the last one may just have gone
                    rtrail("used %s", tostring(safe(function() return item:name() end) or ids[i]))
                    return true
                end
                refused = refused or (safe(function() return item:name() end) or ids[i])
            end
        end
    end
    if held > 0 then
        return false, string.format("%s is in the bags but the client refused to use it", tostring(refused))
    end
    return false, "nothing usable in the bags"
end

local function get_path_runner()
    if path_runner_mod == false then
        return nil
    end
    if type(path_runner_mod) == "table" then
        return path_runner_mod
    end
    local ok, mod = pcall(require, "path_runner")
    if ok and type(mod) == "table" then
        path_runner_mod = mod
        return path_runner_mod
    end
    path_runner_mod = false
    return nil
end

local function is_moving_now(player)
    if movement and type(movement.is_moving) == "function" and movement.is_moving() then
        return true
    end
    return safe(function() return player:is_moving() end) == true
end

local function halt_for_rest(player)
    pcall(function()
        core.input.stop_attack()
    end)
    pcall(function()
        if type(izi.is_sequence_active) == "function" and izi.is_sequence_active() ~= true then
            return
        end
        if izi.sequence and type(izi.sequence.cancel_all) == "function" then
            izi.sequence:cancel_all()
            return
        end
        if type(izi.cancel_sequence) == "function" then
            izi.cancel_sequence()
        end
    end)
    if movement and type(movement.set_resting) == "function" then
        movement.set_resting(true)
    end
    local pr = get_path_runner()
    if pr and type(pr.is_active) == "function" and pr.is_active() == true then
        if type(pr.pause) == "function" then
            pr.pause()
        end
    end
    if movement and type(movement.nav_stop) == "function" then
        if is_moving_now(player) then
            movement.nav_stop()
        elseif type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
    end
end

--- One rest of this kind is over: clear its per-rest use budget.
---
--- MAX_USES caps how many consumables a SINGLE rest may burn while waiting for
--- an aura to appear. It is not a lifetime allowance, so it has to be cleared
--- every time the latch drops - on reaching full, on running out of food, and
--- on a hard reset. Before 1.4.8 only the hard reset cleared it, so the counter
--- accumulated across rests and the bot stopped eating and drinking for good
--- after eight consumables.
local function end_kind(st)
    st.uses = 0
    st.pending = false
    st.warned = false
    st.use_failed = nil
end

local function reset_use_state()
    end_kind(food_state)
    end_kind(drink_state)
end

local function clear_rest()
    rest_eat = false
    rest_drink = false
    resting = false
    reset_use_state()
    if movement and type(movement.set_resting) == "function" then
        movement.set_resting(false)
    end
end

-- ----------------------------------------------------------------------------
-- A CLEAR SPOT TO REST (2.41.0)
-- ----------------------------------------------------------------------------
-- The rest used to be cancelled outright while anything attackable stood
-- within REST_CLEAR_YARDS - rabbits and neutral mobs included - and the tick
-- fell through to the quest engine, which pulled the next mob at 30% health.
-- Quest objectives sit in camps, so there nearly always was something close.
--
-- Now only a real threat counts (hostile to the player or already in combat,
-- not a critter), and instead of giving up the bot walks REST_STEP yards
-- straight away from it and rests there, holding the tick so nothing else can
-- start a fight. After REST_MOVE_MAX of that it sits down regardless: eating
-- next to a mob is still better than fighting at low health.
local REST_STEP = 20
local REST_MOVE_MAX = 12.0
local move_since = 0

local CRITTER = nil
local function is_critter(u)
    if CRITTER == nil then
        local ok, enums = pcall(require, "common/enums")
        CRITTER = (ok and type(enums) == "table" and enums.creature_type and enums.creature_type.CRITTER) or false
    end
    if not CRITTER then
        return false
    end
    local ok, t = pcall(u.get_creature_type, u)
    return ok and t == CRITTER
end

--- The nearest real threat within `yards`, or nil.
local function rest_threat(player, yards)
    -- The shared object-list cache first (2.145.0); the raw call built a
    -- fresh table of every object on each check and was then thrown away.
    local list = nil
    local ok_t, targeting = pcall(require, "targeting")
    if ok_t and targeting and type(targeting.visible_objects) == "function" then
        list = targeting.visible_objects()
    end
    if type(list) ~= "table" then
        list = safe(function() return core.object_manager.get_visible_objects() end)
    end
    if type(list) ~= "table" then
        return nil
    end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return u:is_dead_or_ghost() end) ~= true
            and not is_critter(u) then
            local hostile = safe(function() return u:is_enemy_with(player) end) == true
                or safe(function() return u:is_in_combat() end) == true
            if hostile and safe(function() return player:can_attack(u) end) ~= false then
                local d = safe(function() return player:distance_to(u) end)
                if type(d) == "number" and d <= yards and (best_d == nil or d < best_d) then
                    best, best_d = u, d
                end
            end
        end
    end
    return best
end

--- Walk REST_STEP yards straight away from `threat`. True when a move is on.
local function move_away_from(player, threat)
    local me = safe(function() return player:get_position() end)
    local tp = safe(function() return threat:get_position() end)
    if not me or not tp then
        return false
    end
    local dx, dy = me.x - tp.x, me.y - tp.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.5 then
        dx, dy, len = 1, 0, 1
    end
    local ok_v, vec3 = pcall(require, "common/geometry/vector_3")
    if not ok_v or type(vec3) ~= "table" then
        return false
    end
    local spot = vec3.new(me.x + dx / len * REST_STEP, me.y + dy / len * REST_STEP, me.z)
    if movement and type(movement.set_resting) == "function" then
        movement.set_resting(false)   -- the rest lock would refuse the walk
    end
    if movement and type(movement.is_moving) == "function" and movement.is_moving() then
        return true
    end
    return movement and type(movement.nav_to) == "function" and movement.nav_to(spot, true) == true
end

local function resource_full(pct)
    return pct >= REST_DONE
end

--- Threshold for this kind, as a percentage.
---
--- Supplied by the calling rotation rather than read from a slider, so a class
--- can rest earlier or later than the default without a second GUI control.
--- Clamped so a bad profile cannot make the bot rest at 0% or at full health.
local function start_pct(opts, key, fallback)
    local n = opts and opts[key]
    if type(n) ~= "number" or n ~= n then
        n = fallback
    end
    if n < 5 then
        n = 5
    end
    if n > 95 then
        n = 95
    end
    return n
end

local function latch_rest(hp, mana, has_mana, eat_at, drink_at)
    if hp <= eat_at then
        rest_eat = true
    elseif resource_full(hp) then
        if rest_eat == true then end_kind(food_state) end
        rest_eat = false
    end
    if has_mana == true and mana <= drink_at then
        rest_drink = true
    elseif resource_full(mana) then
        if rest_drink == true then end_kind(drink_state) end
        rest_drink = false
    end
end

--- Use exactly one consumable of this kind, then leave it alone.
---
--- Order matters. The aura check comes first so a working consumable is never
--- stacked; the commit window comes second so a consumable that is working but
--- has not registered yet is not stacked either. Only when both say "nothing is
--- happening" does another get used.
local function consume_one(st, kind, ids, aura_up, now, aura_list)
    -- 1. It is working. Leave it.
    if aura_up == true then
        st.pending = false
        st.warned = false
        return false
    end

    -- 2. Used recently. The aura may simply not have landed yet.
    if (now - st.last) < USE_COMMIT then
        return false
    end

    -- 3. Committed, waited, and still no aura: the aura ids do not cover this
    --    item. Say so once - silently working through the whole stack at one
    --    item per tick is what this guard exists to prevent.
    if st.pending and not st.warned then
        st.warned = true
        core.log_warning(string.format(
            "[Master Farmer - Grindbot] Used %s but no %s aura appeared within %.1fs. "
            .. "consumables.%s is probably missing this item's aura id - "
            .. "capping at %d uses this rest instead of consuming the stack.",
            kind, kind, USE_COMMIT, aura_list, MAX_USES))
    end

    if st.uses >= MAX_USES then
        return false
    end

    local ok, why = use_first(ids)
    if ok then
        st.last = now
        st.uses = st.uses + 1
        st.pending = true
        rest_debug("used one %s (use %d this rest)", kind, st.uses)
        return true
    end

    -- Nothing was consumed and nothing is on cooldown or committed, so the rest
    -- is stalled. Say so - once per rest, naming the reason.
    if st.use_failed ~= why then
        st.use_failed = why
        rtrail("%s: %s", kind, tostring(why))
        core.log_warning(string.format(
            "[Master Farmer - Grindbot] Tried to use %s and nothing happened: %s.", kind, tostring(why)))
    end
    rest_debug("%s blocked - %s", kind, tostring(why))
    return false
end


-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------
--- Is the bot sitting down right now?
function resting_mod.is_resting()
    return resting == true
end

--- Drop every latch. Called when the owner changes or the bot stops.
function resting_mod.clear()
    clear_rest()
end

--- Rest if this character needs to. Returns true while resting, so the caller
--- holds the rest of the tick.
---
--- `opts.eat_pct`   sit and eat at or below this health percentage
--- `opts.drink_pct` sit and drink at or below this mana percentage
--- Both default to REST_DEFAULT.
function resting_mod.tick(player, opts)
    if not player then
        clear_rest()
        return false
    end

    local eat_at = start_pct(opts, "eat_pct", REST_DEFAULT)
    local drink_at = start_pct(opts, "drink_pct", REST_DEFAULT)
    -- The Resting tab's sliders win over the rotation's built-in numbers
    -- (2.41.0): every rotation hard-coded 30%, so "Eat Below HP %" did
    -- nothing. A rotation that passes drink_pct 0 (no mana) keeps it off.
    -- `gui` is this module's own top-level require (2.193.0: no
    -- pcall(require) on every rest tick).
    if type(gui.slider) == "function" then
        local e = gui.slider("eat_hp", nil)
        if type(e) == "number" then
            eat_at = start_pct({ v = e }, "v", eat_at)
        end
        local d = gui.slider("drink_mana", nil)
        if type(d) == "number" and not (opts and opts.drink_pct == 0) then
            drink_at = start_pct({ v = d }, "v", drink_at)
        end
    end

    -- REST PROBE (2.193.0): u:healing was the only multi-millisecond stage
    -- (1.4-1.7 ms) and lined up with the 31 MB heap spike. These marks split
    -- it in the PERF line, and errorlog's SPIKE line names the slow part.
    rprobe("rest:auras")
    local hp = health_pct(player)
    local mana = mana_pct(player)
    local has_mana = power.has_mana(player)
    local eating = has_any_aura(player, FOOD_AURAS)
    local drinking = has_any_aura(player, DRINK_AURAS)
    -- JUST USED (2.110.0): the aura lands a moment after the item is used.
    -- Eating the LAST piece of food left the bags empty before the aura
    -- showed, and the check below read "no usable food - not resting" 0.3 s
    -- into every such rest. An item used in the last JUST_USED s counts as
    -- eating / drinking.
    local now_u = izi.now()
    if eating ~= true and (now_u - food_state.last) < JUST_USED then eating = true end
    if drinking ~= true and (now_u - drink_state.last) < JUST_USED then drinking = true end
    rprobe("rest:food_ids")
    local foods = food_ids(player)
    rprobe("rest:water_ids")
    local waters = water_ids(player)
    rprobe("rest:checks")
    latch_rest(hp, mana, has_mana, eat_at, drink_at)

    -- Combat ends a rest outright. Potions are handled by healing.lua, which
    -- still owns everything that happens while fighting.
    if safe(function() return player:is_in_combat() end) == true then
        rest_debug("in combat - HP %.0f MP %.0f - resting is suppressed until it ends", hp, mana)
        resting = false
        if movement and type(movement.set_resting) == "function" then
            movement.set_resting(false)
        end
        return false
    end
    if safe(function() return core.character.is_swimming() end) == true then
        rest_debug("swimming - cannot sit down to eat or drink")
        clear_rest()
        return false
    end


    if rest_eat == true and eating ~= true and hp < REST_DONE and has_usable(foods) ~= true then
        end_kind(food_state)
        rest_eat = false
        if miss_logged ~= true then
            miss_logged = true
            core.log_warning("[Master Farmer - Grindbot] Eat/drink skipped - no usable food in bags.")
        end
        rtrail("HP %.0f is at the eat line but there is no usable food in the bags - not resting", hp)
    end
    if rest_drink == true and drinking ~= true and mana < REST_DONE and has_usable(waters) ~= true then
        end_kind(drink_state)
        rest_drink = false
        if miss_logged ~= true then
            miss_logged = true
            core.log_warning("[Master Farmer - Grindbot] Eat/drink skipped - no usable water in bags.")
        end
        rtrail("MP %.0f is at the drink line but there is no usable water in the bags - not resting", mana)
    end
    if rest_eat == true or rest_drink == true then
        miss_logged = false
    end

    -- EAT AND DRINK TOGETHER (2.99.0). A rest used to consume only what had
    -- crossed its own line: a mage sitting down at 20% mana with 70% health
    -- drank, stood up at 100% mana with 70% health, and sat down again to eat
    -- a fight later. Once a rest is on for either reason, the other resource
    -- is topped up in the same sit-down when it is under REST_TOPUP and there
    -- is something usable for it; both are used on the same tick and the rest
    -- ends when both are full.
    if rest_eat == true or rest_drink == true then
        if rest_eat ~= true and eating ~= true and hp < REST_TOPUP and has_usable(foods) == true then
            rest_eat = true
            rtrail("also eating (HP %.0f) while resting for mana", hp)
        end
        if rest_drink ~= true and drinking ~= true and has_mana and mana < REST_TOPUP
            and has_usable(waters) == true then
            rest_drink = true
            rtrail("also drinking (MP %.0f) while resting for health", mana)
        end
    end

    -- NOTHING TO EAT OR DRINK (2.139.0). This used to log "no usable food -
    -- not resting" and carry on at low health / mana. Now the rest asks for a
    -- food / water run (supplies.request); when one can happen (a seller
    -- known and gold or junk to pay) the cascade is released so vendor.lua
    -- runs it. When none can, the character stands and waits until health
    -- and mana have come back to REGEN_DONE by themselves. A mage keeps
    -- conjuring meanwhile (conjure.tick runs first, as soon as the mana is
    -- there), and the moment something usable is in the bags the normal rest
    -- takes over.
    rprobe("rest:supplies")
    if rest_eat ~= true and rest_drink ~= true then
        local no_food = hp < eat_at and eating ~= true and has_usable(foods) ~= true
        local no_water = has_mana and mana < drink_at and drinking ~= true and has_usable(waters) ~= true
        if no_food or no_water or regen_wait then
            local ok_s, supplies = pcall(require, "supplies")
            if ok_s and type(supplies) == "table" and type(supplies.request) == "function" then
                if no_food then supplies.request("food") end
                if no_water then supplies.request("water") end
            end
            local recovered = hp >= REGEN_DONE and (not has_mana or mana >= REGEN_DONE)
            local run, why = false, nil
            if ok_s and type(supplies) == "table" and type(supplies.trip_wanted) == "function" then
                run, why = supplies.trip_wanted(player)
            end
            local vendor_busy = state.vendor and state.vendor.active == true
            -- Out of water, health is fine, and one drink is not affordable
            -- yet: stay on the RestedXP step. The run starts on its own once
            -- gold or junk covers the water (2.171.0).
            local water_only = no_water and not no_food and hp >= eat_at
            if water_only and not run and not vendor_busy then
                if not water_stay_logged then
                    water_stay_logged = true
                    rtrail("no water and cannot buy it yet (%s) - staying on the quest", tostring(why))
                end
                regen_wait = false
            elseif recovered or run or vendor_busy then
                water_stay_logged = false
                if regen_wait then
                    rtrail("regen wait over - HP %.0f MP %.0f (%s)", hp, mana,
                        recovered and "recovered" or "going to buy")
                end
                regen_wait = false
            else
                water_stay_logged = false
                if not regen_wait then
                    regen_wait = true
                    rtrail("no %s and no way to buy it (%s) - waiting for HP / MP to reach %d%%",
                        no_food and "food" or "water", tostring(why), REGEN_DONE)
                    if movement and type(movement.nav_stop) == "function" then
                        movement.nav_stop()
                    end
                end
                state.set_note("Rest", string.format("No %s - waiting  HP %.0f%%  MP %.0f%%",
                    (no_food or hp < REGEN_DONE) and "food" or "water", hp, has_mana and mana or 100))
                return true
            end
        end
    end

    rprobe("rest:decide")
    if rest_eat ~= true and rest_drink ~= true then
        rest_debug("no rest needed - HP %.0f (eat at %.0f) MP %.0f (drink at %.0f)",
            hp, eat_at, mana, has_mana and drink_at or 0)
        if resting then
            rtrail("done - HP %.0f MP %.0f", hp, mana)
            -- The fight resumes right after a rest: capture its first moments.
            local el = elog()
            if el and type(el.arm_light) == "function" and gui.is_on("crash_capture") then
                pcall(el.arm_light, 1.5, "rest done")
            end
            reset_use_state()
            if movement and type(movement.set_resting) == "function" then
                movement.set_resting(false)
            end
        end
        resting = false
        return false
    end

    -- A rest is needed. Out of combat is not the same as clear: find a spot
    -- with no real threat within REST_CLEAR_YARDS first.
    local threat = (eating or drinking) and nil or rest_threat(player, REST_CLEAR_YARDS)
    if threat then
        local now_m = izi.now()
        if move_since == 0 then
            move_since = now_m
        end
        if (now_m - move_since) < REST_MOVE_MAX then
            local name = safe(function() return threat:get_name() end) or "mob"
            rest_debug("hostile %s within %d yards - moving away to rest", tostring(name), REST_CLEAR_YARDS)
            state.set_note("Rest", string.format("Moving away from %s to rest", tostring(name)))
            rtrail("rest needed (HP %.0f MP %.0f) - moving away from %s", hp, mana, tostring(name))
            rprobe("rest:move_away")
            move_away_from(player, threat)
            return true               -- hold the tick: no new pull at low health
        end
        rest_debug("no clear spot after %.0fs - resting where it stands", REST_MOVE_MAX)
    end
    move_since = 0

    if not resting then
        rtrail("start - HP %.0f (eat %s) MP %.0f (drink %s)", hp, tostring(rest_eat), mana, tostring(rest_drink))
        -- The flight recorder, when its box is ticked, covers the start of
        -- every rest: the halt, the sit and the first item use.
        local el = elog()
        if el and type(el.arm) == "function" and gui.is_on("crash_recorder") then
            pcall(el.arm, "rest start")
        end
    end
    resting = true
    rprobe("rest:halt")
    rest_debug("resting - HP %.0f MP %.0f - eat=%s drink=%s - %d food / %d water ids known",
        hp, mana, tostring(rest_eat), tostring(rest_drink), #foods, #waters)
    halt_for_rest(player)
    state.set_note("Rest", string.format("Eating / drinking  HP %.0f  MP %.0f", hp, mana))

    if safe(function() return player:is_mounted() end) == true then
        -- One dismount per second (2.217.0), not one per tick.
        local now = izi.now()
        if (now - (state.rest_dismount_t or -1e9)) >= 1.0 then
            state.rest_dismount_t = now
            rest_debug("mounted - dismounting first")
            pcall(core.input.dismount)
        end
        return true
    end
    if is_moving_now(player) then
        rest_debug("still moving - waiting for the character to stop")
        return true
    end

    local now = izi.now()

    if rest_eat and hp < REST_DONE then
        consume_one(food_state, "food", foods, eating, now, "FOOD_AURA_IDS")
    end
    if rest_drink and mana < REST_DONE then
        consume_one(drink_state, "drink", waters, drinking, now, "DRINK_AURA_IDS")
    end
    return true
end

return resting_mod
