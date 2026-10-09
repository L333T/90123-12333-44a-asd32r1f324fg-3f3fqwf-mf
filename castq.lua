-- ============================================================================
-- Master Farmer - Grindbot
-- castq.lua - rotation casts through the Sylvanas spell queue
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.254.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY (2.249.0)
--   smart.lua sent every rotation spell through izi's cast_safe and returned
--   while the player was casting, so the next spell was only chosen once the
--   cast bar had finished: a dead gap after every cast.
--
-- WHAT (common/modules/spell_queue, as documented)
--   * PRIORITY 1 for every rotation spell - the rotation's own order decides
--     what is cast; higher priorities stay free for interrupt / dispel
--     plugins and the player's own keys.
--   * GCD spells: queue_spell_target / queue_spell_position.
--   * OFF-GCD spells (izi's spell_gcd data: skips_gcd, else a base GCD of 0
--     that the client reports): the _fast variants, ONE AT A TIME - the next
--     off-GCD spell waits until is_in_fast_queue says the previous one left.
--   * QUEUE AHEAD: smart.lua may pick and queue the next GCD spell in the last
--     QUEUE_WINDOW seconds of a cast (never during a channel), so it goes out
--     the moment the cast ends.
--   * No spam: the same spell at the same target is queued at most every
--     REQUEUE_GAP seconds while it is still waiting in the queue.
--   * Every cast is checked first (spellcheck.lua / spell_helper
--     is_spell_castable) by the caller.
--   Without the module the caller falls back to izi's cast_safe.
-- ============================================================================

local M = {}

M.PRIORITY = 1
M.QUEUE_WINDOW = 0.35        -- s before a cast ends: the next GCD spell may be queued
local REQUEUE_GAP = 0.25

local sq = nil               -- spell_queue, false when unavailable
local last = {}              -- "id|guid" -> time queued
local last_n = 0
local last_fast_id = nil
-- STUCK QUEUE (2.251.0): queued spells that never leave the queue. After
-- STUCK_LIMIT of them the queue is switched off for the session (izi casts).
-- 2.254.0: 1.0 s / 2 spells. The 03:38 Rogue log: Sinister Strike re-queued
-- every 0.3 s for 2 s without going out; each re-queue reset its time here,
-- so the queue never looked stuck. The FIRST queue time is kept now.
local STUCK_S = 1.0
local STUCK_LIMIT = 2
local pending = {}           -- id -> time queued (GCD spells)
local stuck = 0
M.disabled = false

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local t = ok and type(izi) == "table" and safe(izi.now) or nil
    if t then return t end
    local ms = safe(function() return core.game_time() end)
    return ms and ms / 1000 or 0
end

local function queue_mod()
    if sq == nil then
        local ok, m = pcall(require, "common/modules/spell_queue")
        sq = (ok and type(m) == "table" and type(m.queue_spell_target) == "function") and m or false
    end
    return sq or nil
end

--- Is the spell queue available?
function M.available()
    return not M.disabled and queue_mod() ~= nil
end

local function in_queue(Q, id)
    local snap = safe(function() return Q:get_queue_snapshot() end)
    if type(snap) ~= "table" then return nil end
    for i = 1, #snap do
        if type(snap[i]) == "table" and snap[i].spell_id == id then return true end
    end
    return false
end

--- Call every tick: a queued spell still waiting after STUCK_S never went
--- out. It is purged; STUCK_LIMIT of them switch the queue off (`on_stuck`
--- is told why, once). Returns the id of a spell purged this tick (the
--- caller casts it directly), or nil.
function M.check_stuck(on_stuck)
    local Q = queue_mod()
    if not Q or M.disabled then return nil end
    local t = now()
    for id, qt in pairs(pending) do
        local waiting = in_queue(Q, id)
        if waiting == false then
            pending[id] = nil           -- went out
            stuck = 0
        elseif t - qt >= STUCK_S then
            pending[id] = nil
            if waiting == true then
                M.purge(id)
                stuck = stuck + 1
                if stuck >= STUCK_LIMIT then
                    M.disabled = true
                    if on_stuck then
                        pcall(on_stuck, string.format("%d queued spells never left the spell queue (last: %d) - "
                            .. "spell queue casting is off for this session, casting through izi", stuck, id))
                    end
                end
                return id
            end
        end
    end
    return nil
end

--- Does spell `id` (izi spell `sp` when known) skip the global cooldown?
function M.off_gcd(id, sp)
    if sp and type(sp.skips_gcd) == "function" then
        local v = safe(function() return sp:skips_gcd() end)
        if type(v) == "boolean" then return v end
    end
    local base = safe(function() return core.spell_book.get_spell_base_cooldown(id) end)
    -- A 0 also means "the client does not say": only a known cooldown with a
    -- 0 GCD counts as off-GCD.
    if type(base) == "table" and tonumber(base.cooldown_ms) and base.cooldown_ms > 0 and base.gcd_ms == 0 then
        return true
    end
    return false
end

--- Seconds left on the player's current cast (not a channel), or 0.
function M.cast_left(player)
    if not player then return 0 end
    local t = safe(function() return core.game_time() end)
    local fin = safe(function() return player:get_active_spell_cast_end_time() end)
    if type(t) ~= "number" or type(fin) ~= "number" or fin <= 0 then return 0 end
    local left = (fin - t) / 1000
    if left < 0 then return 0 end
    return left
end

--- Is the player channeling?
function M.channeling(player)
    local t = safe(function() return core.game_time() end)
    local fin = safe(function() return player:get_active_channel_cast_end_time() end)
    return type(t) == "number" and type(fin) == "number" and fin > t
end

--- May the rotation pick its next spell now? Not casting, or in the last
--- QUEUE_WINDOW of a cast (queue ahead). Never during a channel.
function M.may_queue(player)
    if not player then return false end
    if M.channeling(player) then return false end
    local casting = safe(function() return player:is_casting() end)
    if casting ~= true then
        if safe(function() return player:is_channeling_or_casting() end) == true then return false end
        return true
    end
    local left = M.cast_left(player)
    return left > 0 and left <= M.QUEUE_WINDOW
end

local function guid_of(u)
    return u and safe(function() return u:get_guid() end) or "self"
end

--- Queue spell `id` (izi spell `sp` optional) at `target` (or at `pos` for a
--- ground spell). Returns true when queued, false + reason otherwise.
function M.cast(id, sp, target, pos, message, allow_movement)
    local Q = queue_mod()
    if not Q then return false, "no_queue" end
    if type(id) ~= "number" or id <= 0 then return false, "no_id" end
    local t = now()
    local key = tostring(id) .. "|" .. tostring(pos and "pos" or guid_of(target))
    if last[key] and t - last[key] < REQUEUE_GAP then
        return false, "requeue_gap"
    end
    local fast = M.off_gcd(id, sp)
    if fast and last_fast_id and type(Q.is_in_fast_queue) == "function"
        and safe(function() return Q:is_in_fast_queue(last_fast_id) end) == true then
        return false, "fast_queue_busy"
    end
    local ok
    if pos then
        if fast then
            ok = pcall(Q.queue_spell_position_fast, Q, id, pos, M.PRIORITY, message, allow_movement == true)
        else
            ok = pcall(Q.queue_spell_position, Q, id, pos, M.PRIORITY, message, allow_movement == true)
        end
    elseif fast then
        ok = pcall(Q.queue_spell_target_fast, Q, id, target, M.PRIORITY, message, allow_movement == true)
    else
        ok = pcall(Q.queue_spell_target, Q, id, target, M.PRIORITY, message, allow_movement == true)
    end
    if not ok then return false, "queue_error" end
    last_n = last_n + 1
    if last_n > 200 then last, last_n = {}, 0 end
    last[key] = t
    if fast then last_fast_id = id else pending[id] = pending[id] or t end
    return true, fast and "fast" or "gcd"
end

--- Drop every queued entry of `id` (a cast the rotation no longer wants).
function M.purge(id, target)
    local Q = queue_mod()
    if not Q or type(Q.purge_by_spell) ~= "function" then return 0 end
    return safe(function() return Q:purge_by_spell(id, target) end) or 0
end

return M
