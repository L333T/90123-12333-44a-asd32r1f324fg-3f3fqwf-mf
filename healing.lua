-- ============================================================================
-- Master Farmer - Grindbot
-- Eat / drink / potions
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 1.4.7
-- Folder: Master_Farmer_Grindbot_v1.4.7
-- Out of combat: if HP or mana is 35% or lower, FORCE-pause combat and movement,
-- then eat and/or drink until that resource is 100% before restarting.
-- Combat still uses potions. Swimming cannot rest.
--
-- ONE ITEM AT A TIME
--   A consumable is used, then nothing else of that kind is used until either
--   its aura drops or the resource is full. Two things make that reliable:
--
--   * A COMMIT WINDOW. There is a round trip between using the item and the
--     aura appearing. Without a wait the next tick sees "no aura" and consumes
--     a second one, so each use commits for USE_COMMIT seconds no matter what
--     the aura says.
--
--   * SEPARATE TIMERS for food and drink. They used to share one, so eating
--     delayed drinking and vice versa - and in TBC both auras can run at once.
--
--   If the commit window passes and the aura still has not appeared, the aura
--   id list is wrong for that item and the old code would quietly eat the whole
--   stack, one every 1.5s. That now logs once, names the item, and stops at
--   MAX_USES instead of draining the bags.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local consumables = require("data/consumables")
local gui = require("gui")
local rotation = require("rotation")
local movement = require("movement")
local state = require("state")

local healing = {}

local FOOD_AURAS = consumables.FOOD_AURA_IDS
local DRINK_AURAS = consumables.DRINK_AURA_IDS
local FOOD_ITEM_RANK = consumables.FOOD_ITEM_IDS
local WATER_ITEM_RANK = consumables.WATER_ITEM_IDS

local REST_START = 35
local REST_DONE = 100

-- Seconds a use is committed for before another of the same kind is considered.
-- Covers the delay between using the item and its aura becoming visible.
-- Measured against the worst case, not the typical one: a 3s window still
-- double-consumed when the aura took 4.5s to register.
local USE_COMMIT = 5.0
-- Worst-case bound per rest session if aura detection is broken entirely.
local MAX_USES = 8

local food_state  = { last = -1e9, uses = 0, pending = false, warned = false }
local drink_state = { last = -1e9, uses = 0, pending = false, warned = false }
local rest_eat = false
local rest_drink = false
local resting = false
local miss_logged = false
local item_by_id = {}
local path_runner_mod = nil

local function item_of(id)
    if type(id) ~= "number" then
        return nil
    end
    local cached = item_by_id[id]
    if cached then
        return cached
    end
    local item = izi.item(id)
    if item then
        item_by_id[id] = item
    end
    return item
end

for i = 1, #FOOD_ITEM_RANK do
    local id = FOOD_ITEM_RANK[i]
    local item = izi.item(id)
    if item then
        item_by_id[id] = item
    end
end
for i = 1, #WATER_ITEM_RANK do
    local id = WATER_ITEM_RANK[i]
    local item = izi.item(id)
    if item then
        item_by_id[id] = item
    end
end

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

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

local function mana_pct(player)
    local maxm = safe(function() return player:mana_max() end)
    if type(maxm) == "number" and maxm <= 0 then
        return 100
    end
    local pct = safe(function() return player:mana_pct() end)
    local cur = safe(function() return player:mana_current() end)
    return as_percent(pct, cur, maxm)
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
    for i = 1, #base do
        add(base[i])
    end
    if type(extra) == "table" then
        for i = 1, #extra do
            add(extra[i])
        end
    end
    return out
end

local function food_ids(player)
    return ranked_ids(FOOD_ITEM_RANK, rotation.preferred_food_ids(player))
end

local function water_ids(player)
    return ranked_ids(WATER_ITEM_RANK, rotation.preferred_drink_ids(player))
end

local function has_usable(ids)
    if type(ids) ~= "table" then
        return false
    end
    for i = 1, #ids do
        local item = item_of(ids[i])
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

local function use_first(ids)
    if type(ids) ~= "table" then
        return false
    end
    for i = 1, #ids do
        local item = item_of(ids[i])
        if item then
            local count = safe(function() return item:count() end) or 0
            local ready = safe(function() return item:cooldown_up() end) == true
            if count > 0 and ready then
                local ok = safe(function()
                    return item:use_self_safe("Consume")
                end)
                if ok == true then
                    return true
                end
            end
        end
    end
    return false
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

local function reset_use_state()
    food_state.uses, food_state.pending = 0, false
    drink_state.uses, drink_state.pending = 0, false
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

local function resource_full(pct)
    return pct >= REST_DONE
end

local function start_pct(key)
    local n = gui.slider(key, REST_START)
    if type(n) ~= "number" or n ~= n then
        n = REST_START
    end
    if n < 20 then
        n = 20
    end
    if n > REST_START then
        n = REST_START
    end
    return n
end

local function latch_rest(hp, mana, has_mana)
    if hp <= start_pct("eat_hp") then
        rest_eat = true
    elseif resource_full(hp) then
        rest_eat = false
    end
    if has_mana == true and mana <= start_pct("drink_mana") then
        rest_drink = true
    elseif resource_full(mana) then
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

    if use_first(ids) then
        st.last = now
        st.uses = st.uses + 1
        st.pending = true
        return true
    end
    return false
end

function healing.is_resting()
    return resting == true
end

function healing.tick(player)
    if not player then
        clear_rest()
        return false
    end
    if gui.is_on("eat_drink") ~= true then
        clear_rest()
        return false
    end

    local hp = health_pct(player)
    local mana = mana_pct(player)
    local maxm = safe(function() return player:mana_max() end)
    local has_mana = type(maxm) == "number" and maxm > 0
    local eating = has_any_aura(player, FOOD_AURAS)
    local drinking = has_any_aura(player, DRINK_AURAS)
    local foods = food_ids(player)
    local waters = water_ids(player)
    latch_rest(hp, mana, has_mana)

    if safe(function() return player:is_in_combat() end) == true then
        resting = false
        if movement and type(movement.set_resting) == "function" then
            movement.set_resting(false)
        end
        if gui.is_on("potions") then
            if hp <= gui.slider("hp_pot", 35) then
                izi.use_best_health_potion_safe()
            end
            if has_mana and mana <= gui.slider("mp_pot", 20) then
                izi.use_best_mana_potion_safe()
            end
        end
        return false
    end
    if safe(function() return core.character.is_swimming() end) == true then
        clear_rest()
        return false
    end

    if rest_eat == true and eating ~= true and hp < REST_DONE and has_usable(foods) ~= true then
        rest_eat = false
        if miss_logged ~= true then
            miss_logged = true
            core.log_warning("[Master Farmer - Grindbot] Eat/drink skipped — no usable food in bags.")
        end
    end
    if rest_drink == true and drinking ~= true and mana < REST_DONE and has_usable(waters) ~= true then
        rest_drink = false
        if miss_logged ~= true then
            miss_logged = true
            core.log_warning("[Master Farmer - Grindbot] Eat/drink skipped — no usable water in bags.")
        end
    end
    if rest_eat == true or rest_drink == true then
        miss_logged = false
    end

    if rest_eat ~= true and rest_drink ~= true then
        if resting and movement and type(movement.set_resting) == "function" then
            movement.set_resting(false)
        end
        resting = false
        return false
    end

    resting = true
    halt_for_rest(player)
    state.set_note("Rest", string.format("Eating / drinking  HP %.0f  MP %.0f", hp, mana))

    if safe(function() return player:is_mounted() end) == true then
        pcall(function()
            core.input.dismount()
        end)
        return true
    end
    if is_moving_now(player) then
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

return healing
