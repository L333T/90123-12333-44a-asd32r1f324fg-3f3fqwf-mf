-- ============================================================================
-- restedXP_questing
-- mage_poly.lua - Mage: Polymorph an add while the target is killed
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.27.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.17.0 (user: "if player == Mage create a gui option to enable/disable
-- 'Polymorph' if enemy targets >= Players level and Player health is below
-- 50% or mana is below 50% then cast 'Polymorph' SpellID: 12825 on one of the
-- enemy targets while killing the other enemy target"). Class tab, Mages
-- only: "Polymorph an Add" (on by default).
--
-- smart.lua runs P.tick right after the interrupts. Polymorph is cast when:
--   * the box is ticked and the player is a Mage in a fight with a target;
--   * 2+ enemies are on the player (the fight's pack, targeting.combat_scan);
--   * the player is under HP_PCT % health OR under MANA_PCT % mana;
--   * no pack member is crowd-controlled already (combatcheck is_cc_weak - a
--     sheep still standing is not cast again; one that broke is re-sheeped);
--   * an ADD qualifies - not the target being killed, alive, at or above
--     the player's level, a Humanoid / Beast / Critter (all Polymorph takes),
--     not immune to crowd control, within RANGE yd. Several: the one with
--     the most health left (the longest fight saved for last).
-- Rank: 12825 (the user's id) when known, else the best known of
-- 12826 / 12824 / 118. Cast at the add by the core API
-- (spellcheck.core_cast -> core.input.cast_target_spell: the current target
-- stays the target, so the kill goes on). At most one try every GAP s; the
-- add gets HOLD s for the cast to land before it is tried again.
-- The rotation's AoE / control spells already hold off where they would hit
-- a crowd-controlled pack member (4.14.0, smart.lua ck_refuse).
-- ============================================================================

local P = {}

P.KEY = "mage_poly"
P.IDS = { 12825, 12826, 12824, 118 }     -- the user's 12825 first, then the other ranks
P.HP_PCT, P.MANA_PCT = 50, 50
P.RANGE = 30
P.GAP, P.HOLD = 1.0, 4.0
P.MAGE = 8

local next_try = 0
local held = {}            -- guid -> until
local logged_t = -1e9

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function m(o, name, ...)
    if not o then return nil end
    local f = o[name]
    if type(f) ~= "function" then return nil end
    return safe(f, o, ...)
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local t = ok and type(izi) == "table" and safe(izi.now) or nil
    return type(t) == "number" and t or 0
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "rotation", fmt, ...) end
end

local function mod(name)
    local ok, r = pcall(require, name)
    if ok and type(r) == "table" then return r end
    return nil
end

local function pct(cur, max)
    cur, max = tonumber(cur), tonumber(max)
    if cur and max and max > 0 then return cur / max * 100 end
    return nil
end

local function health_pct(u)
    local v = tonumber(m(u, "get_health_percentage"))
    if v then return v end
    return pct(m(u, "get_health"), m(u, "get_max_health"))
end

local function mana_pct(p)
    local pw = mod("power")
    if pw and type(pw.mana_pct) == "function" then
        local v = tonumber(safe(pw.mana_pct, p))
        if v then return v end
    end
    return pct(m(p, "get_power", 0), m(p, "get_max_power", 0))
end

local SHEEPABLE = nil
local function sheepable(u)
    if SHEEPABLE == nil then
        local okE, enums = pcall(require, "common/enums")
        local ct = okE and type(enums) == "table" and enums.creature_type or nil
        SHEEPABLE = {}
        if type(ct) == "table" then
            for _, k in ipairs({ "HUMANOID", "BEAST", "CRITTER" }) do
                if type(ct[k]) == "number" then SHEEPABLE[ct[k]] = true end
            end
        end
    end
    if next(SHEEPABLE) == nil then return true end          -- no enum table: the game decides
    return SHEEPABLE[m(u, "get_creature_type")] == true
end

--- The best known Polymorph spell id, or nil.
function P.spell_id()
    local sb = core and core.spell_book
    if type(sb) ~= "table" then return nil end
    for i = 1, #P.IDS do
        local id = P.IDS[i]
        if safe(sb.is_spell_learned, id) == true or safe(sb.has_spell, id) == true
            or safe(sb.is_spell_known, id) == true then
            return id
        end
    end
    return nil
end

local function enabled()
    local ok, gui = pcall(require, "gui")
    return ok and type(gui) == "table" and type(gui.is_on) == "function" and gui.is_on(P.KEY) == true
end

--- The add to Polymorph from `pack` (not `target`), or nil (and why).
function P.pick(player, target, pack)
    if type(pack) ~= "table" or #pack < 2 then return nil, "fewer than 2 enemies" end
    local ck = mod("combatcheck")
    local tg = m(target, "get_guid")
    local my_lvl = tonumber(m(player, "get_level")) or 1
    local t = now()
    local best, best_hp = nil, nil
    for i = 1, #pack do
        local u = pack[i]
        if ck and ck.weak_cc(u) == true then return nil, "a pack member is crowd-controlled already" end
    end
    for i = 1, #pack do
        local u = pack[i]
        local g = m(u, "get_guid")
        if u and g ~= nil and g ~= tg and m(u, "is_valid") ~= false and m(u, "is_dead") ~= true
            and m(u, "is_player") ~= true and (held[g] or 0) <= t then
            local lvl = tonumber(m(u, "get_level")) or 0
            local d = tonumber(m(player, "distance_to", u)) or 99
            if lvl >= my_lvl and d <= P.RANGE and sheepable(u) and not (ck and ck.cc_immune(u) == true) then
                local hp = health_pct(u) or 100
                if not best_hp or hp > best_hp then best, best_hp = u, hp end
            end
        end
    end
    if not best then return nil, "no add at or above your level that Polymorph takes" end
    return best
end

--- In a fight: Polymorph an add when the player is in trouble. True when cast.
function P.tick(player, target, pack)
    if not player or not target or not enabled() then return false end
    if tonumber(m(player, "get_class")) ~= P.MAGE then return false end
    if m(player, "is_in_combat") ~= true then return false end
    local t = now()
    if t < next_try then return false end
    local hp, mp = health_pct(player), mana_pct(player)
    if not ((hp and hp < P.HP_PCT) or (mp and mp < P.MANA_PCT)) then return false end
    local add, why = P.pick(player, target, pack)
    if not add then return false end
    local id = P.spell_id()
    if not id then return false end
    next_try = t + P.GAP
    local sc = mod("spellcheck")
    local ok = sc and type(sc.core_cast) == "function" and sc.core_cast(id, add) == true
    if ok then
        held[m(add, "get_guid")] = t + P.HOLD
        if t - logged_t > 3 then
            logged_t = t
            trail("Polymorph (%d) on %s (level %s) - health %.0f%%, mana %.0f%%, %d enemies; still killing %s",
                id, tostring(m(add, "get_name")), tostring(m(add, "get_level")), hp or -1, mp or -1, #pack,
                tostring(m(target, "get_name")))
        end
        return true
    end
    return false
end

function P._reset() next_try, held, logged_t, SHEEPABLE = 0, {}, -1e9, nil end

return P
