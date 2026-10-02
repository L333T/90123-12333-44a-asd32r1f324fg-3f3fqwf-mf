-- ============================================================================
-- Master Farmer - Grindbot
-- Conjured food and water, for mages
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.193.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- A mage never has to buy food or water, and until now the bot made it do
-- exactly that: supplies.lua walked it to a vendor to spend copper on
-- Refreshing Spring Water while Conjure Water sat unused on the bar. Worse,
-- on a route with no vendor in its README the mage simply ran out and then
-- sat in the rest state with nothing to drink.
--
-- WHEN IT RUNS
--   Out of combat, when the conjured stock is below the top-up mark, and
--   never while the player is actually eating or drinking. That last one is
--   not a nicety: conjuring is a cast, and a cast cancels the sit, so a
--   conjure fired mid-drink would throw away the mana it just started to
--   regain and then loop.
--
-- WHICH RANK
--   The highest the character actually knows. The rank tables in
--   data/consumables run highest first, so this walks them in order and casts
--   the first one the spellbook confirms - no level table to keep in step
--   with the game, and a mage that has not trained the newest rank still
--   conjures the one it has.
--
-- WHY IT SITS AHEAD OF RESTING
--   main.lua calls this before healing.tick. A mage with no water needs to
--   conjure BEFORE the rest logic looks in the bags, or the rest finds
--   nothing, reports empty bags, and the bot stands there at low mana.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type enums
local enums = require("common/enums")

local consumables = require("data/consumables")
local auras = require("auras")
local state = require("state")

local conjure = {}

-- Conjuring makes a stack. Keep at most this many of each in the bags.
local KEEP = 20

local CAST_GAP = 2.5         -- seconds between conjure attempts
local FAIL_GAP = 15.0        -- back-off after one that did not land

local last_cast = -1e9
local fail_until = 0

-- NOT EVERY FRAME (2.114.0). Counting water and food means one item lookup
-- per id - conjured AND bought, a few hundred - and since 2.103.0 that ran on
-- every frame: u:conjure cost 1.2-1.3 ms/frame in the 02:03 log, more than the
-- whole rest of the bot, and frame rate fell from ~245 to ~160. When a check
-- finds nothing to do (bags stocked, nothing trained) the next one waits
-- IDLE_RECHECK seconds. A stop-to-conjure or a cast in progress still runs
-- every frame, and a combat / rest / attacker interruption is not delayed.
local IDLE_RECHECK = 2.0
local idle_until = 0

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

--- Is this character a mage? Everything here is a no-op otherwise.
function conjure.is_mage(player)
    if not player then
        return false
    end
    local want = (enums and enums.class_id and enums.class_id.MAGE) or 8
    local got = safe(function() return player:get_class() end)
    if type(got) ~= "number" then
        got = safe(function() return player:get_class_id() end)
    end
    return got == want
end

--- How many of `ids` are carried, added up across every rank.
local function held(ids)
    local n = 0
    if type(ids) ~= "table" then
        return 0
    end
    for i = 1, #ids do
        local item = safe(function() return izi.item(ids[i]) end)
        if item then
            local c = safe(function() return item:count() end)
            if type(c) == "number" and c > 0 then
                n = n + c
            end
        end
    end
    return n
end

--- The highest rank of `spell_ids` the character actually knows.
--- The tables are ordered highest first, so the first one in the spellbook
--- is the best. has_spell and is_spell_known are both accepted: a learned
--- rank is in the book either way.
local function best_known(spell_ids)
    if type(spell_ids) ~= "table" then
        return nil
    end
    for i = 1, #spell_ids do
        local id = spell_ids[i]
        local known = safe(function() return core.spell_book.has_spell(id) end) == true
            or safe(function() return core.spell_book.is_spell_known(id) end) == true
        if known then
            return id
        end
    end
    return nil
end

--- Is the player mid meal? Casting now would cancel it.
local function consuming(player)
    if auras.aura_up(player, consumables.FOOD_AURA_IDS) then
        return true
    end
    return auras.aura_up(player, consumables.DRINK_AURA_IDS)
end

local function cast(spell_id, label)
    local spell = safe(function() return izi.spell(spell_id) end)
    if not spell then
        return false
    end
    local ok = safe(function() return spell:cast_safe(nil, label) end)
    if ok ~= true then
        ok = safe(function() return spell:cast(nil, label) end)
    end
    return ok == true
end

-- ----------------------------------------------------------------------------
-- TICK
-- ----------------------------------------------------------------------------
--- Top up conjured water and food. Returns true when it cast something, so
--- the caller holds the rest of its tick.
-- PAUSE TO CONJURE (2.103.0) ------------------------------------------------
-- Conjuring is a 3 s cast and was fired while the bot walked (quest travel,
-- grind routes): the cast failed, the 15 s back-off started, and the mage went
-- on with empty bags. Now, when a mage needs water or food and nothing else is
-- going on - not in combat, nobody attacking, not resting / eating /
-- drinking, not mounted - movement is stopped first, a cast lock holds the
-- walker for the cast, and the tick is held until the conjure is done. Then
-- movement resumes on its own. "Needs" is the conjured stock only, under
-- KEEP: vendor food does not stand in for a conjure, and a full 20 stops it.
local CAST_HOLD = 5.0        -- seconds the cascade is held for a conjure in progress
local movement_mod = nil

local function get_movement()
    if movement_mod == nil then
        local ok, m = pcall(require, "movement")
        movement_mod = (ok and type(m) == "table") and m or false
    end
    return movement_mod or nil
end

--- Combat, an attacker, mounted, resting or mid-meal: not now.
local function busy_elsewhere(player)
    if safe(function() return player:is_in_combat() end) == true then return true end
    if safe(function() return player:is_mounted() end) == true then return true end
    local ok_t, targeting = pcall(require, "targeting")
    if ok_t and type(targeting) == "table" and type(targeting.attackers) == "function"
        and targeting.attackers(player) > 0 then
        return true
    end
    local ok_h, healing = pcall(require, "healing")
    if ok_h and type(healing) == "table" and type(healing.is_resting) == "function" and healing.is_resting() then
        return true
    end
    -- Mid meal. Conjuring would cancel the sit and waste the rest.
    return consuming(player)
end

function conjure.tick(player)
    if not player or not conjure.is_mage(player) then
        return false
    end
    if busy_elsewhere(player) then
        return false
    end

    local now = izi.now()
    -- Our conjure is being cast: hold everything else until it lands.
    if safe(function() return player:is_channeling_or_casting() end) == true then
        return (now - last_cast) < CAST_HOLD
    end
    if (now - last_cast) < CAST_GAP then
        return false
    end
    if now < fail_until then
        return false
    end
    if now < idle_until then
        return false
    end

    -- Water first. Only conjured stacks count, and only while that spell is
    -- in the book: the highest known rank, stopped at KEEP.
    local water_spell = best_known(consumables.CONJURE_WATER_SPELL_IDS)
    local food_spell = best_known(consumables.CONJURE_FOOD_SPELL_IDS)
    local want_water = water_spell ~= nil and held(consumables.CONJURED_WATER_ITEM_IDS) < KEEP
    local want_food = food_spell ~= nil and held(consumables.CONJURED_FOOD_ITEM_IDS) < KEEP

    if not want_water and not want_food then
        idle_until = now + IDLE_RECHECK
        return false
    end

    local spell_id, label
    if want_water then
        spell_id = water_spell
        label = "Conjure Water"
    elseif want_food then
        spell_id = food_spell
        label = "Conjure Food"
    end
    if not spell_id then
        -- Nothing trained yet. A level 1 mage has neither, and backing off
        -- stops this re-checking the whole spellbook every frame.
        fail_until = now + FAIL_GAP
        return false
    end

    -- Stop first: a conjure cannot be cast on the move.
    -- ENOUGH MANA FIRST (2.139.0). With too little mana the cast failed and
    -- the 15 s back-off started; the resting code now waits for mana when
    -- there is nothing to drink, so the conjure just waits for the moment
    -- the spell is castable (core.spell_book.is_usable_spell covers mana).
    if safe(function() return core.spell_book.is_usable_spell(spell_id) end) == false then
        state.set_note("Conjure", "Waiting for mana to " .. label)
        idle_until = now + 1.0
        return false
    end
    local mv = get_movement()
    local moving = safe(function() return player:is_moving() end) == true
        or (mv and type(mv.is_moving) == "function" and mv.is_moving() == true)
    if moving then
        if mv and type(mv.nav_stop) == "function" then pcall(mv.nav_stop) end
        state.set_note("Conjure", "Stopping to " .. label)
        return true
    end
    -- Hold the walker for the cast (conjure cast time + margin).
    local ct = 3.0
    local sp = safe(function() return izi.spell(spell_id) end)
    local ms = sp and safe(function() return sp:cast_time_ms() end)
    if type(ms) == "number" and ms > 0 then ct = ms / 1000 end
    if mv and type(mv.prepare_cast) == "function" then
        pcall(mv.prepare_cast, nil, ct + 0.3)
    end

    last_cast = now
    if cast(spell_id, label) then
        state.set_note("Conjure", label)
        return true
    end

    -- Out of mana, or the client refused. Let the walker go and back off.
    if mv and type(mv.release) == "function" then pcall(mv.release) end
    fail_until = now + FAIL_GAP
    return false
end

--- Forget the back-off timers. Called when the bot stops.
--- Does this mage know Conjure Water ("water") / Conjure Food ("food")?
--- supplies.lua asks, so a mage who conjures it is not sent to a vendor.
function conjure.knows(kind)
    local ok_p, me = pcall(function() return izi.me() end)
    if not ok_p or not me or not conjure.is_mage(me) then return false end
    if kind == "water" then
        return best_known(consumables.CONJURE_WATER_SPELL_IDS) ~= nil
    end
    return best_known(consumables.CONJURE_FOOD_SPELL_IDS) ~= nil
end

function conjure.reset()
    last_cast = -1e9
    fail_until = 0
end

return conjure
