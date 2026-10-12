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
    -- 2.306.0 (audit LUA-3): os may be absent in the sandbox
    if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
    return 0
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
-- 2.311.0: in_los / in_los_position removed - spell_helper traces a ray for them
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
        -- 2.311.0: no line-of-sight query here (spell_helper traces a ray)
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
    -- 2.311.0: never the helper's line-of-sight trace (skip_los always)
    local answer = ask("is_spell_castable", id, caster, target, skip_facing, skip_range,
        nil, nil, nil, true)
    return verdict(id, answer, function() return M.why(id, caster, target) end)
end

--- May `spell` be cast at the position `pos` now (ground spells)?
function M.can_cast_at(spell, caster, target, pos, opts)
    local id = M.id_of(spell)
    if not id or not caster or not pos then return true, nil end
    opts = opts or {}
    local answer = ask("is_spell_castable_position", id, caster, target or caster, pos,
        opts.skip_facing ~= false, opts.skip_range == true, nil, nil, nil, nil, true)
    return verdict(id, answer, function() return M.why(id, caster, target, pos) end)
end

--- A cast went out: the refusal streak starts again.
function M.cast_done(spell, target)
    local id = M.id_of(spell)
    if id then streak[id] = nil end
    -- 2.315.0: the last spell sent (was izi.on_spell_success, movement/fsm.lua)
    local F = package.loaded["movement/fsm"]
    if id and type(F) == "table" and type(F.note_spell) == "function" then pcall(F.note_spell, id, target) end
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

-- ----------------------------------------------------------------------------
-- 2.312.0: CORE API CASTS AND ITEM USES (the Slave Pens correction). Slave
-- Pens stopped crashing once its izi spell / item / spell-queue calls were
-- replaced by the core API ("Use Core API and not IZI"); the drink crashes
-- were inside an izi item use, the step-37 crashes inside an izi cast. The
-- same is done here: a cast is checked with core.spell_book and sent with
-- core.input.cast_target_spell / cast_position_spell, an item with
-- core.input.use_item. No line-of-sight ray anywhere; the game refuses what
-- it will not cast and says why (UI_ERROR_MESSAGE, events.lua).
-- ----------------------------------------------------------------------------
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function busy(p)
    return call(p.is_casting_spell, p) == true or call(p.is_channelling_spell, p) == true
end

local CORE_REFUSED = { reason = "core" }
local CORE_SENT = { reason = "core_sent" }

--- Learned (either core answer), usable, off cooldown, not casting, and in
--- range of `target` when it is not the player. Returns ok, why.
function M.core_castable(id, target, opts)
    local me = local_player()
    if not id or not me then return false, "no player" end
    local o = type(opts) == "table" and opts or {}
    local sb = core.spell_book
    if type(sb) ~= "table" then return false, "no spell_book" end
    if call(sb.is_spell_learned, id) == false and call(sb.has_spell, id) == false then
        return false, "not learned"
    end
    if call(sb.is_usable_spell, id) == false then return false, "not usable" end
    local cd = tonumber(call(sb.get_spell_cooldown, id)) or 0
    if cd > 0.05 and o.skip_gcd ~= true then return false, "cooldown" end
    if o.skip_casting ~= true and busy(me) then return false, "casting" end
    if target and not same(target, me) and o.skip_range ~= true
        and call(sb.is_spell_in_range, id, target, me) == false then
        return false, "out of range"
    end
    return true, nil
end

--- Cast `sp` (izi spell or id) at `target` (the player when nil) - core API.
function M.core_cast(sp, target, opts)
    local id = M.id_of(sp)
    local me = local_player()
    local t = target or me
    if not id or not t then return false, CORE_REFUSED end
    local ok, why = M.core_castable(id, t, opts)
    if not ok then return false, { reason = "core: " .. tostring(why) } end
    if call(core.input.cast_target_spell, id, t) == true then return true, CORE_SENT end
    return false, CORE_REFUSED
end

--- Cast a ground spell at `pos` - core API.
function M.core_cast_position(sp, pos, opts)
    local id = M.id_of(sp)
    if not id or not pos then return false, CORE_REFUSED end
    local ok, why = M.core_castable(id, nil, opts)
    if not ok then return false, { reason = "core: " .. tostring(why) } end
    if call(core.input.cast_position_spell, id, pos) == true then return true, CORE_SENT end
    return false, CORE_REFUSED
end

--- Use item `item` (izi item or id) on the player - core API. Not while
--- casting, and not while moving unless opts.skip_moving (food and drink
--- cannot be used on the move), as Slave Pens' coreapi.lua.
function M.use_item(item, opts)
    local id = M.id_of(item)
    local me = local_player()
    if not id or not me then return false end
    local o = type(opts) == "table" and opts or {}
    if busy(me) then return false end
    if o.skip_moving ~= true and call(me.is_moving, me) == true then return false end
    local okc, cd = pcall(me.get_item_cooldown, me, id)
    if okc and type(cd) == "number" and cd > 0 then return false end
    return call(core.input.use_item, id) == true
end

--- 2.311.0: NO LINE-OF-SIGHT RAYS ON A CAST. izi unit / position casts run
--- two line-of-sight traces by default (izi_sdk.lua unit_cast_opts
--- check_los: "Omitted or true: both traces run"); check_los = false runs
--- neither. The game still refuses a cast it considers out of sight, and
--- that refusal is what movement/range.lua reads. Returns a copy of opts.
function M.no_los(opts)
    local o = {}
    if type(opts) == "table" then for k, v in pairs(opts) do o[k] = v end end
    o.check_los = false
    return o
end

function M.cast_safe(sp, target, msg, opts)
    if not gate_unit(sp, target, opts) then return false, REFUSED end
    local ok, meta = M.core_cast(sp, target, opts)       -- 2.312.0: core API, not izi
    if ok == true then M.cast_done(sp, target) end
    return ok, meta
end

function M.cast(sp, target, msg, opts)
    if not gate_unit(sp, target, opts) then return false, REFUSED end
    local ok, meta = M.core_cast(sp, target, opts)       -- 2.312.0: core API, not izi
    if ok == true then M.cast_done(sp, target) end
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
    local ok, meta = M.core_cast_position(sp, pos, opts) -- 2.312.0: core API, not izi
    if ok == true then M.cast_done(sp, nil) end
    return ok, meta
end

return M
