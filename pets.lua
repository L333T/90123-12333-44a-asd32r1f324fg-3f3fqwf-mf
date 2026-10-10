-- ============================================================================
-- Master Farmer - Grindbot
-- pets.lua - shared pet handling for Hunter and Warlock
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.277.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Shared on purpose. Hunter and Warlock both need summon / revive / heal /
-- attack / stance, differing only in spell ids and in whether summoning costs a
-- reagent. Duplicating that in two rotation files is how the two copies drift.
--
-- API (confirmed present in the reflected reference):
--   unit:get_pet()                        the pet object, or nil
--   unit:is_pet()
--   core.spell_book.get_pet_happiness()   Hunter only; Warlock pets have none
--   core.input.pet_attack / set_pet_passive / set_pet_defensive / set_pet_follow
--
-- THE ORDERING RULE THAT MATTERS
--   Out of combat the pet is set PASSIVE. The reference bot does this too, and
--   it is not cosmetic: an aggressive pet wanders into neighbouring packs while
--   the bot is pathing and pulls everything. Combat sets it back to attack.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local state = require("state")

local pets = {}

local ACT_GAP = 1.5

-- ----------------------------------------------------------------------------
-- PET HANDLER
-- ----------------------------------------------------------------------------
-- common/utility/pet_handler drives the pet through a state enum - PASSIVE,
-- DEFENSIVE, ASSIST - rather than one-shot key presses, and ASSIST is the
-- interesting one: the pet follows whatever the player is attacking on its
-- own, so a grinding bot that changes target every few seconds stops having
-- to re-issue an attack command (and stops resetting the pet's swing timer
-- every time it does).
--
-- IT MAY NOT BE THERE
--   The reflected API dump for this TBC build enumerates twelve
--   common/utility modules and pet_handler is not among them, while
--   core.input.set_pet_passive / set_pet_defensive / set_pet_assist /
--   pet_attack all are. So the handler is resolved optionally and every
--   call falls back to core.input, which is what this file used before and
--   is confirmed to exist. Nothing here depends on the handler being
--   present.
--
-- DELAYED COMMANDS NEED on_render
--   set_pet_state and move_pet_to_position take a delay, and a delayed
--   command only fires if pet_handler:on_render() is pumped every frame.
--   pets.on_render does that, and main.lua calls it from its render
--   callback. Nothing here passes a delay today, but a delay that silently
--   never fires is a nasty thing to leave for whoever adds one.
local handler = nil
local handler_tried = false

local function pet_handler()
    if handler_tried then
        return handler
    end
    handler_tried = true
    local ok, mod = pcall(require, "common/utility/pet_handler")
    if ok and type(mod) == "table" and type(mod.set_pet_state) == "function" then
        handler = mod
    else
        handler = nil
    end
    return handler
end

--- One of the handler's state constants, or nil when it cannot be reached.
local function pet_state(name)
    local h = pet_handler()
    if not h or type(h.pet_state) ~= "table" then
        return nil
    end
    local v = h.pet_state[name]
    if type(v) == "number" then
        return v
    end
    return nil
end

-- HUNTER GATE (2.223.0)
--   A Hunter uses the pet handler only at level 10 or higher and only with a
--   live pet out; at level 9 or lower (no pet yet) the handler is ignored -
--   not resolved, not pumped. Other classes (the Warlock) use it as before.
--   The answer is cached GATE_TTL s, since on_render asks every frame.
local GATE_TTL = 1.0
local HUNTER_PET_LEVEL = 10
local gate = { t = -1e9, ok = false }

local function hunter_class_id()
    local ok, enums = pcall(require, "common/enums")
    if ok and type(enums) == "table" and type(enums.class_id) == "table" then
        return enums.class_id.HUNTER
    end
    return nil
end

--- May `player` (default: the local player) drive the pet handler now?
function pets.handler_allowed(player)
    local now = izi.now()
    if (now - gate.t) < GATE_TTL then return gate.ok end
    gate.t = now
    if not player then
        local okm, me = pcall(izi.me)
        player = okm and me or nil
    end
    local allowed = false
    if player then
        local okc, cid = pcall(function() return player:get_class() end)
        local hunter = hunter_class_id()
        if okc and hunter ~= nil and cid == hunter then
            local okl, lvl = pcall(function() return player:get_level() end)
            allowed = okl and type(lvl) == "number" and lvl >= HUNTER_PET_LEVEL
                and pets.alive(player) == true
        else
            allowed = true
        end
        -- Resolved only once allowed: a level 1-9 Hunter never loads it.
        if allowed then allowed = pet_handler() ~= nil end
    end
    gate.ok = allowed
    return allowed
end

--- The handler when this player may use it, else nil.
local function handler_for(player)
    if not pets.handler_allowed(player) then return nil end
    return pet_handler()
end

--- Set the pet state through the handler: "PASSIVE", "DEFENSIVE" or
--- "ASSIST", optionally after `delay` s (needs pets.on_render pumped).
--- Returns false when the handler is absent or not allowed, so the caller
--- falls through to core.input rather than assuming it worked.
function pets.set_state(player, name, delay)
    local h = handler_for(player)
    local v = pet_state(name)
    if not h or v == nil then
        return false
    end
    local ok = pcall(function()
        if type(delay) == "number" and delay > 0 then
            h:set_pet_state(v, delay)
        else
            h:set_pet_state(v)
        end
    end)
    return ok
end

--- Send the pet to a world position (optionally after `delay` s, staying
--- `duration` s). Position is copied into a fresh vec3. False when the
--- handler is absent, not allowed, or the position is bad.
function pets.move_to(player, pos, delay, duration)
    local h = handler_for(player)
    if not h or type(h.move_pet_to_position) ~= "function" or type(pos) ~= "table" and type(pos) ~= "userdata" then
        return false
    end
    local okp, x, y, z = pcall(function() return pos.x, pos.y, pos.z end)
    if not okp or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return false
    end
    local okv, vec3 = pcall(require, "common/geometry/vector_3")
    if not okv or type(vec3) ~= "table" then return false end
    local v = vec3.new(x, y, z)
    local d = (type(delay) == "number" and delay > 0) and delay or 0
    local ok = pcall(function()
        if type(duration) == "number" and duration > 0 then
            h:move_pet_to_position(v, d, duration)
        else
            h:move_pet_to_position(v, d)
        end
    end)
    return ok
end

local function set_state(player, name)
    return pets.set_state(player, name)
end

--- Pump the handler's delayed-command queue. Called once per frame from
--- main.lua's render callback; a no-op when there is no handler, or for a
--- Hunter below level 10 / without a live pet.
function pets.on_render()
    local h = handler_for(nil)
    if h and type(h.on_render) == "function" then
        pcall(function()
            h:on_render()
        end)
    end
end

--- Whether the richer pet control is actually available on this build.
function pets.has_handler()
    return pet_handler() ~= nil
end

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

-- ----------------------------------------------------------------------------
-- STATE
-- ----------------------------------------------------------------------------
--- The live pet object, or nil. A dead pet still returns an object, so callers
--- that need "usable pet" must also check `pets.alive`.
function pets.get(player)
    if not player then
        return nil
    end
    local pet = safe(function() return player:get_pet() end)
    if pet and safe(function() return pet:is_valid() end) == true then
        return pet
    end
    return nil
end

function pets.alive(player)
    local pet = pets.get(player)
    if not pet then
        return false
    end
    if safe(function() return pet:is_dead_or_ghost() end) == true then
        return false
    end
    if safe(function() return pet:is_dead() end) == true then
        return false
    end
    return true
end

function pets.exists(player)
    return pets.get(player) ~= nil
end

function pets.health_pct(player)
    local pet = pets.get(player)
    if not pet then
        return nil
    end
    local pct = safe(function() return pet:health_pct() end)
    if type(pct) == "number" then
        if pct >= 0 and pct <= 1.5 then
            return pct * 100
        end
        return pct
    end
    local cur = safe(function() return pet:get_health() end)
    local mx = safe(function() return pet:get_max_health() end)
    if type(cur) == "number" and type(mx) == "number" and mx > 0 then
        return (cur / mx) * 100
    end
    return nil
end

--- Hunter pet happiness, 1 unhappy .. 3 content. nil for classes without it.
function pets.happiness()
    -- WoW Forever (2.123.0): the core returns a placeholder table there
    -- (happiness 0, damage 100%, loyalty 0), not the pet's real state.
    local ok_g, gamever = pcall(require, "gamever")
    if ok_g and type(gamever) == "table" and gamever.is_forever() then
        return nil
    end
    local h = safe(function() return core.spell_book.get_pet_happiness() end)
    if type(h) == "number" then
        return h
    end
    if type(h) == "table" and type(h.happiness) == "number" then
        return h.happiness
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- CONTROL
-- ----------------------------------------------------------------------------
local last_stance = 0
local last_attack = -1e9

--- Park the pet. Out of combat an aggressive pet pulls packs the bot never
--- chose to fight, which is the single biggest source of unattended deaths.
-- PET MODE (2.225.0): what the pet was last told - "passive" or "assist".
local pet_mode = nil
local ATTACK_HOLD = 6.0      -- no recall this soon after sending the pet in

local function pet_fighting(player)
    local pet = pets.get(player)
    return pet ~= nil and safe(function() return pet:is_in_combat() end) == true
end

function pets.passive(player)
    if not pets.alive(player) then
        return false
    end
    local now = izi.now()
    if (now - last_stance) < ACT_GAP then
        return false
    end
    -- Not during a pull (2.225.0): the hunter sends the pet in before its own
    -- first shot puts it in combat, and the out-of-combat upkeep then called
    -- the pet straight back. Nor while the pet is still fighting.
    if (now - last_attack) < ATTACK_HOLD or pet_fighting(player) then
        return false
    end
    last_stance = now
    pet_mode = "passive"
    if not set_state(player, "PASSIVE") then
        pcall(function() core.input.set_pet_passive() end)
    end
    -- Follow is not part of the handler's state enum, and parking the pet
    -- means bringing it back as well as telling it to stop.
    pcall(function() core.input.set_pet_follow() end)
    return true
end

--- Send the pet at the current target.
function pets.attack(player, target)
    if not target or not pets.alive(player) then
        return false
    end
    local now = izi.now()
    if (now - last_attack) < ACT_GAP then
        return false
    end

    -- Only re-issue when the pet is not already attacking this target:
    -- pet_attack resets its swing timer, so spamming it lowers pet damage.
    -- ATTACKING, NOT TARGETING (2.225.0): a pet parked passive keeps its old
    -- target, so "same target" alone skipped the command and the pet stood
    -- by while the hunter fought. Skip only when it was sent in (assist) and
    -- is in combat on this target.
    local pet = pets.get(player)
    local pet_target = safe(function() return pet:get_target() end)
    if pet_target and pet_mode == "assist" and pet_fighting(player) then
        local a = safe(function() return pet_target:get_guid() end)
        local b = safe(function() return target:get_guid() end)
        if a ~= nil and a == b then
            return false
        end
    end

    last_attack = now
    pet_mode = "assist"

    -- ASSIST means the pet tracks the player's target by itself, which is
    -- what a grinding bot wants: the target changes constantly and every
    -- re-issued attack command resets the pet's swing timer.
    if not set_state(player, "ASSIST") then
        pcall(function() core.input.set_pet_assist() end)
        pcall(function() core.input.set_pet_defensive() end)
    end

    -- Still sent explicitly. ASSIST decides what the pet picks up next; this
    -- is what puts it on THIS target now rather than at its own pace.
    --
    -- core.input.pet_attack(target) takes the target. It was being called
    -- with no argument, inside a pcall, so the pet was never actually sent
    -- in and nothing said so - it only fought what hit it first.
    pcall(function() core.input.pet_attack(target) end)
    return true
end

-- ----------------------------------------------------------------------------
-- MAINTENANCE
-- ----------------------------------------------------------------------------
--- Out-of-combat pet upkeep shared by both classes.
---
--- `spec` supplies the class's spells and rules:
---   summon        spell   cast when there is no pet
---   revive        spell   cast when the pet is dead        (Hunter)
---   heal          spell   cast below heal_pct              (Mend Pet / Health Funnel)
---   heal_ids      table   buff ids proving the heal is already ticking
---   heal_pct      number  threshold, default 50
---   can_summon    fun()   extra gate, e.g. Warlock soul shard check
---   learned       fun(sp) spell-known test from the calling rotation
---   cast_self     fun(sp,label) cast helper from the calling rotation
---   min_level     number  do not try below this (Hunter pets start at 10)
---
--- Returns true when it acted, so the rotation can hold the cascade.
function pets.maintain(player, spec)
    if not player or type(spec) ~= "table" then
        return false
    end
    local learned = spec.learned
    local cast_self = spec.cast_self
    if type(learned) ~= "function" or type(cast_self) ~= "function" then
        return false
    end

    if type(spec.min_level) == "number" then
        local lvl = safe(function() return player:get_level() end)
        if type(lvl) == "number" and lvl < spec.min_level then
            return false
        end
    end

    local exists = pets.exists(player)
    local alive = pets.alive(player)

    -- 1. dead pet -> revive (Hunter). A Warlock has no revive; it re-summons.
    if exists and not alive then
        if spec.revive and learned(spec.revive) then
            state.set_note("Pet", "Reviving pet")
            return cast_self(spec.revive, player, "Revive Pet")
        end
    end

    -- 2. no pet at all -> summon
    if not exists or not alive then
        if spec.summon and learned(spec.summon) then
            if type(spec.can_summon) == "function" and spec.can_summon() ~= true then
                return false
            end
            state.set_note("Pet", "Summoning pet")
            return cast_self(spec.summon, player, spec.summon_label or "Summon Pet")
        end
        return false
    end

    -- 3. wounded pet -> heal, but only if the heal is not already running.
    --    Re-casting a channelled pet heal clips it for no gain.
    if spec.heal and learned(spec.heal) then
        local pct = pets.health_pct(player)
        local threshold = spec.heal_pct or 50
        if type(pct) == "number" and pct < threshold then
            local pet = pets.get(player)
            local ticking = false
            if spec.heal_ids and pet then
                ticking = safe(function() return pet:has_buff(spec.heal_ids) end) == true
            end
            if not ticking then
                state.set_note("Pet", "Healing pet")
                return cast_self(spec.heal, player, spec.heal_label or "Mend Pet")
            end
        end
    end

    return false
end

-- ----------------------------------------------------------------------------
-- HUNTER: CALL PET / REVIVE PET (2.222.0)
-- ----------------------------------------------------------------------------
-- Hard-coded ids: Call Pet 883, Revive Pet 982. A dismissed pet and a dead
-- one can look the same from here - player:get_pet() answers nil for both
-- once the corpse is gone - and Call Pet on a dead pet fails ("Your pet is
-- dead"), which used to set the 15 s fail gap and never revived it. So:
--   * a pet object that is dead           -> Revive Pet
--   * no pet, and it was last seen dying  -> Revive Pet first
--   * no pet otherwise (dismissed)        -> Call Pet first
-- When the first spell has not brought a pet up within its wait, the other
-- one is cast. Both tried and still no pet (none tamed, stabled) -> wait
-- NO_PET_HOLD s before trying again.
pets.CALL_PET_ID = 883
pets.REVIVE_PET_ID = 982

local CALL_WAIT = 3.0        -- Call Pet is instant: a pet within this, or it failed
local REVIVE_WAIT = 13.0     -- Revive Pet casts 10 s
local NO_PET_HOLD = 60.0
local DYING_PCT = 25         -- a pet last seen this low that vanishes is taken as dead

local hp = { order = nil, step = 0, t = 0, hold = 0, last_pct = nil, last_t = -1e9, died = false }

local function hunter_knows(id)
    if safe(function() return core.spell_book.is_spell_learned(id) end) == true then return true end
    return safe(function() return core.spell_book.has_spell(id) end) == true
end

--- Hunter pet presence. `spec`:
---   call, revive  spell entries for the caller's cast (ids 883 / 982)
---   cast          fun(entry):boolean
--- Returns true when it cast or is waiting on its own cast (hold the
--- cascade), false when there is nothing to do or it cannot act, and nil when
--- the pet is up and alive (the caller goes on to the heal).
function pets.hunter_pet(player, spec)
    if not player or type(spec) ~= "table" or type(spec.cast) ~= "function" then return false end
    local now = izi.now()
    local pet = pets.get(player)
    if pet and pets.alive(player) then
        hp.order, hp.step, hp.died, hp.hold = nil, 0, false, 0
        hp.last_pct, hp.last_t = pets.health_pct(player), now
        return nil
    end
    if pet then hp.died = true end                      -- a dead pet object
    if not pet and hp.order == nil and hp.last_pct and (now - hp.last_t) < 30
        and hp.last_pct <= DYING_PCT then
        hp.died = true                                  -- vanished while dying
    end
    if now < hp.hold then return false end
    if safe(function() return player:is_channeling_or_casting() end) == true then
        return hp.order ~= nil                           -- Revive Pet still casting
    end
    local knows_call = hunter_knows(pets.CALL_PET_ID)
    local knows_revive = hunter_knows(pets.REVIVE_PET_ID)
    if not knows_call and not knows_revive then return false end

    if hp.order == nil then
        if hp.died or pet then
            hp.order = { "revive", "call" }
        else
            hp.order = { "call", "revive" }
        end
        hp.step, hp.t = 0, -1e9
    end
    -- The current step gets its wait before the next one is tried.
    if hp.step > 0 then
        local wait = (hp.order[hp.step] == "revive") and REVIVE_WAIT or CALL_WAIT
        if (now - hp.t) < wait then return true end
    end
    -- Skip what cannot work: an unknown spell, or Call Pet with a dead pet object.
    local nxt = hp.step + 1
    while hp.order[nxt] do
        local k = hp.order[nxt]
        if (k == "call" and knows_call and not pet) or (k == "revive" and knows_revive) then break end
        nxt = nxt + 1
    end
    local which = hp.order[nxt]
    if not which then
        hp.order, hp.step, hp.hold = nil, 0, now + NO_PET_HOLD
        state.set_note("Pet", "No pet answered Call Pet / Revive Pet")
        return false
    end
    hp.step, hp.t = nxt, now
    state.set_note("Pet", which == "revive" and "Reviving pet" or "Calling pet")
    if not spec.cast(which == "revive" and spec.revive or spec.call) then
        -- Refused here (not usable: Call Pet with the pet dead, say): the
        -- next spell after 1 s rather than the full wait.
        local wait = (which == "revive") and REVIVE_WAIT or CALL_WAIT
        hp.t = now - wait + 1.0
    end
    return true
end

return pets
