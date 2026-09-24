-- ============================================================================
-- Master Farmer - Grindbot
-- Conjured food and water, for mages
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.6.1
-- Folder: Master_Farmer_Grindbot_v2.3.0
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
local spellbook = require("spellbook")
local auras = require("auras")
local state = require("state")

local conjure = {}

-- Conjuring makes a stack, so this does not need to be large. It is the mark
-- below which a top-up happens, not a target count.
local LOW_WATER = 5
local LOW_FOOD = 5

local CAST_GAP = 2.5         -- seconds between conjure attempts
local FAIL_GAP = 15.0        -- back-off after one that did not land

local last_cast = -1e9
local fail_until = 0

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
--- The tables are ordered highest first, so the first known one is the best.
local function best_known(spell_ids)
    if type(spell_ids) ~= "table" then
        return nil
    end
    for i = 1, #spell_ids do
        local id = spell_ids[i]
        local known = safe(function() return spellbook.spell_known(id) end)
        if known ~= true then
            known = safe(function() return core.spell_book.has_spell(id) end)
        end
        if known == true then
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
function conjure.tick(player)
    if not player or not conjure.is_mage(player) then
        return false
    end

    -- Combat, mounted, dead or already casting: not now.
    if safe(function() return player:is_in_combat() end) == true then
        return false
    end
    if safe(function() return player:is_mounted() end) == true then
        return false
    end

    -- Mid meal. Conjuring would cancel the sit and waste the rest.
    if consuming(player) then
        return false
    end

    local now = izi.now()
    if (now - last_cast) < CAST_GAP then
        return false
    end
    if now < fail_until then
        return false
    end

    -- Water first. A mage out of water is stuck; a mage out of food can still
    -- drink its health back up far more slowly, so water is the binding one.
    local want_water = held(consumables.CONJURED_WATER_ITEM_IDS) < LOW_WATER
    local want_food = held(consumables.CONJURED_FOOD_ITEM_IDS) < LOW_FOOD

    if not want_water and not want_food then
        return false
    end

    local spell_id, label
    if want_water then
        spell_id = best_known(consumables.CONJURE_WATER_SPELL_IDS)
        label = "Conjure Water"
    end
    if not spell_id and want_food then
        spell_id = best_known(consumables.CONJURE_FOOD_SPELL_IDS)
        label = "Conjure Food"
    end
    if not spell_id then
        -- Nothing trained yet. A level 1 mage has neither, and backing off
        -- stops this re-checking the whole spellbook every frame.
        fail_until = now + FAIL_GAP
        return false
    end

    last_cast = now
    if cast(spell_id, label) then
        state.set_note("Conjure", label)
        return true
    end

    -- Out of mana, or the client refused. Back off rather than spinning.
    fail_until = now + FAIL_GAP
    return false
end

--- Forget the back-off timers. Called when the bot stops.
function conjure.reset()
    last_cast = -1e9
    fail_until = 0
end

return conjure
