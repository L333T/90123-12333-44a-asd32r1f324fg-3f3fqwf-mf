-- ============================================================================
-- spellcheck.lua - Sylvanas spell_helper, one guarded gate for every cast
-- (Master Farmer, shared by every project)
-- ============================================================================
-- require("common/utility/spell_helper") - accessed with ":" - answers:
--   has_spell_equipped(id)                      in the spellbook
--   is_spell_on_cooldown(id)                    on cooldown
--   is_spell_in_range(id, target, src, dst)     in range
--   is_spell_within_angle(id, caster, target, cpos, tpos)
--   is_spell_in_line_of_sight(id, caster, target)
--   is_spell_in_line_of_sight_position(id, caster, pos)
--   get_spell_cost(id) / can_afford_spell(unit, id, costs)
--   is_spell_castable(id, caster, target, skip_facing, skip_range)
--   is_spell_castable_position(id, caster, target, pos, skip_facing, skip_range)
--
-- M.can_cast / M.can_cast_at are the gate the cast paths call before a cast:
-- is_spell_castable answers for line of sight, cooldown, cost, range and
-- facing in one call (self casts skip facing and range).
--
-- NEVER A STALL (2.250.0). A "no" blocks only a spell the client confirms is
-- on cooldown. Missing helper, an error or any other refusal answers "yes"
-- (logged once per spell and reason) - the cast path's own izi checks run.
-- ============================================================================

local M = {}


local helper = nil           -- spell_helper, false when it cannot be loaded
local streak = {}            -- id -> { n, t }
local logger = nil

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local ok2, t = pcall(izi.now)
        if ok2 and type(t) == "number" then return t end
    end
    local ok3, ms = pcall(function() return core.game_time() end)
    if ok3 and type(ms) == "number" then return ms / 1000 end
    return os.clock()
end

local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then return end
    if logger then
        pcall(logger, msg)
        return
    end
    local ok_e, el = pcall(require, "errorlog")
    if ok_e and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "spellcheck", "%s", msg)
    else
        pcall(function() core.log("[spellcheck] " .. msg) end)
    end
end

--- Where to send the "keeps refusing" line (default core.log).
function M.set_logger(fn)
    logger = type(fn) == "function" and fn or nil
end

--- The spell_helper module, or nil.
function M.helper()
    if helper == nil then
        local ok, h = pcall(require, "common/utility/spell_helper")
        helper = (ok and type(h) == "table") and h or false
    end
    return helper or nil
end

--- A spell id from a number or an izi spell (sp:id()).
function M.id_of(x)
    if type(x) == "number" then return x end
    if type(x) == "table" then
        if type(x.id) == "function" then
            local ok, v = pcall(x.id, x)
            if ok and type(v) == "number" then return v end
        elseif type(x.id) == "number" then
            return x.id
        end
    end
    return nil
end

local function ask(name, ...)
    local h = M.helper()
    if not h or type(h[name]) ~= "function" then return nil end
    local ok, v = pcall(h[name], h, ...)
    if ok then return v end
    return nil
end

-- ----------------------------------------------------------------------------
-- The individual checks (nil = could not be answered)
-- ----------------------------------------------------------------------------
function M.has(spell) return ask("has_spell_equipped", M.id_of(spell)) end
function M.on_cooldown(spell) return ask("is_spell_on_cooldown", M.id_of(spell)) end
function M.in_range(spell, target, src, dst) return ask("is_spell_in_range", M.id_of(spell), target, src, dst) end
function M.within_angle(spell, caster, target, cpos, tpos)
    return ask("is_spell_within_angle", M.id_of(spell), caster, target, cpos, tpos)
end
function M.in_los(spell, caster, target) return ask("is_spell_in_line_of_sight", M.id_of(spell), caster, target) end
function M.in_los_position(spell, caster, pos)
    return ask("is_spell_in_line_of_sight_position", M.id_of(spell), caster, pos)
end
function M.cost(spell) return ask("get_spell_cost", M.id_of(spell)) end
function M.can_afford(unit, spell)
    local id = M.id_of(spell)
    local costs = ask("get_spell_cost", id)
    if type(costs) ~= "table" then return nil end
    return ask("can_afford_spell", unit, id, costs)
end

local function pos_of(u)
    if not u or type(u.get_position) ~= "function" then return nil end
    local ok, p = pcall(u.get_position, u)
    if ok then return p end
    return nil
end

--- Which check failed, for the log line.
function M.why(spell, caster, target, pos)
    if M.has(spell) == false then return "not in the spellbook" end
    if M.on_cooldown(spell) == true then return "on cooldown" end
    if caster and M.can_afford(caster, spell) == false then return "not enough resource" end
    if target and target ~= caster then
        local cp, tp = pos_of(caster), pos or pos_of(target)
        if cp and tp and M.in_range(spell, target, cp, tp) == false then return "out of range" end
        if pos then
            if M.in_los_position(spell, caster, pos) == false then return "no line of sight" end
        elseif M.in_los(spell, caster, target) == false then
            return "no line of sight"
        end
        if cp and tp and not pos and M.within_angle(spell, caster, target, cp, tp) == false then
            return "not facing"
        end
    end
    return "not castable now (moving / casting / unusable)"
end

-- ----------------------------------------------------------------------------
-- The gate
-- ----------------------------------------------------------------------------
-- 2.250.0: THE HELPER ADVISES, THE CLIENT DECIDES. A Rogue on 2.246-2.249
-- cast nothing: spell_helper refused its strikes for reasons the client did
-- not share, each refusal put the spell on the rotation's 1-2 s fail gap, and
-- the "let it through after ~10 s" bypass needed 40 refusals - a minute or
-- more per spell, long after every fight was over. Now a refusal blocks only
-- when the CLIENT confirms the spell is on cooldown
-- (core.spell_book.get_spell_cooldown); any other disagreement is logged once
-- per spell and reason (DISAGREE_LOG_GAP) and the cast path's own izi checks
-- decide.
local DISAGREE_LOG_GAP = 120
local disagree_t = {}        -- "id|why" -> time logged

local function native_cooldown(id)
    local ok, cd = pcall(function() return core.spell_book.get_spell_cooldown(id) end)
    if ok and type(cd) == "number" then return cd > 0 end
    return nil
end

local function verdict(id, answer, why_fn)
    if answer ~= false then
        if answer == true then streak[id] = nil end
        return true, nil
    end
    local why = tostring(why_fn())
    if why == "on cooldown" and native_cooldown(id) ~= false then
        return false, "cooldown"
    end
    local key = tostring(id) .. "|" .. why
    local t = now()
    if t - (disagree_t[key] or -1e9) >= DISAGREE_LOG_GAP then
        disagree_t[key] = t
        log("spell %d: spell_helper says no (%s) - left to the cast's own checks", id, why)
    end
    return true, "helper_disagrees"
end

--- May `spell` (id or izi spell) be cast at `target` now?
--- opts: self (skip facing and range), skip_facing, skip_range, skip_los.
--- Returns ok, reason - reason is nil, "cooldown" (refused) or "helper_disagrees" (let through).
function M.can_cast(spell, caster, target, opts)
    local id = M.id_of(spell)
    if not id or not caster then return true, nil end
    opts = opts or {}
    target = target or caster
    local self_cast = opts.self == true or target == caster
    local skip_facing = opts.skip_facing == true or self_cast
    local skip_range = opts.skip_range == true or self_cast
    local answer = ask("is_spell_castable", id, caster, target, skip_facing, skip_range,
        nil, nil, nil, opts.skip_los == true)
    return verdict(id, answer, function() return M.why(id, caster, target) end)
end

--- May `spell` be cast at the position `pos` now (ground spells)?
function M.can_cast_at(spell, caster, target, pos, opts)
    local id = M.id_of(spell)
    if not id or not caster or not pos then return true, nil end
    opts = opts or {}
    local answer = ask("is_spell_castable_position", id, caster, target or caster, pos,
        opts.skip_facing ~= false, opts.skip_range == true, nil, nil, nil, nil, opts.skip_los == true)
    return verdict(id, answer, function() return M.why(id, caster, target, pos) end)
end

--- A cast went out: the refusal streak starts again.
function M.cast_done(spell)
    local id = M.id_of(spell)
    if id then streak[id] = nil end
end

-- ----------------------------------------------------------------------------
-- Gated izi casts: the same call and the same answer as sp:cast_safe /
-- sp:cast / sp:cast_position, after the spell_helper gate. A refusal answers
-- false, { reason = "spell_helper" } without touching the spell queue.
-- ----------------------------------------------------------------------------
local function local_player()
    local ok, p = pcall(function() return core.object_manager.get_local_player() end)
    if ok then return p end
    return nil
end

local function same(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local ok1, g1 = pcall(function() return a:get_guid() end)
    local ok2, g2 = pcall(function() return b:get_guid() end)
    return ok1 and ok2 and g1 ~= nil and g1 == g2
end

local function gate_unit(sp, target, opts)
    local me = local_player()
    if not me then return true end
    local o = type(opts) == "table" and opts or {}
    return (M.can_cast(sp, me, target or me, {
        self = target == nil or same(target, me),
        skip_facing = o.skip_facing == true,
        skip_range = o.skip_range == true,
        skip_los = o.check_los == false,
    }))
end

local REFUSED = { reason = "spell_helper" }

function M.cast_safe(sp, target, msg, opts)
    if not gate_unit(sp, target, opts) then return false, REFUSED end
    local ok, meta = sp:cast_safe(target, msg, opts)
    if ok == true then M.cast_done(sp) end
    return ok, meta
end

function M.cast(sp, target, msg, opts)
    if not gate_unit(sp, target, opts) then return false, REFUSED end
    local ok, meta = sp:cast(target, msg, opts)
    if ok == true then M.cast_done(sp) end
    return ok, meta
end

function M.cast_position(sp, pos, msg, opts)
    local me = local_player()
    if me and pos then
        local o = type(opts) == "table" and opts or {}
        if not M.can_cast_at(sp, me, nil, pos, { skip_range = o.skip_range == true, skip_los = o.check_los == false }) then
            return false, REFUSED
        end
    end
    local ok, meta = sp:cast_position(pos, msg, opts)
    if ok == true then M.cast_done(sp) end
    return ok, meta
end

return M
