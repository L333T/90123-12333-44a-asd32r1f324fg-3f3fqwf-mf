-- ============================================================================
-- restedXP_questing
-- trinkets.lua - on-use trinkets in the rotation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.27.0
-- Folder: restedXP_questing
-- ============================================================================
-- 4.16.0 (user: "Create GUI options to enable/disable trinket slots, When
-- enabled use trinkets during rotation"). Class tab: "Use Top Trinket (slot
-- 13)" / "Use Bottom Trinket (slot 14)", both off by default.
--
-- The two slots are read every SCAN_GAP s: player:get_item_at_inventory_slot
-- (slot).object:get_item_id() (.api game_object: the row has no item_id
-- field), and a trinket counts only with a "Use:" effect -
-- core.quests.get_item_spell(id) answers a spell (every client since the
-- 2026-10-06 core). Passive trinkets are never pressed.
--
-- smart.lua runs trinkets.tick right after the racials, in a fight with a
-- live target: a ticked slot's trinket is used when its item cooldown is 0
-- (player:get_item_cooldown) and the fight is worth it - the target above
-- MIN_TARGET_HP %, or 2+ enemies on the player, or the player under
-- LOW_HP % (a defensive trinket). Never mounted. Used through the core API
-- (spellcheck.use_item -> core.input.use_item; no izi casts, 2.312.0).
-- At most one press per USE_GAP s per slot; a press the client refused
-- waits RETRY s.
-- ============================================================================

local T = {}

T.SLOTS = { 13, 14 }
T.KEYS = { [13] = "trinket1", [14] = "trinket2" }
T.SCAN_GAP = 2.0
T.USE_GAP = 1.0
T.RETRY = 5.0
T.MIN_TARGET_HP = 30
T.LOW_HP = 50

local info = { [13] = false, [14] = false }   -- slot -> { id, name, spell } | false
local last_scan = -1e9
local next_try = { [13] = 0, [14] = 0 }
local logged = {}

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function now()
    local ok, izi = pcall(require, "common/izi_sdk")
    local t = ok and type(izi) == "table" and safe(izi.now) or nil
    return type(t) == "number" and t or 0
end

local function m(o, name, ...)
    if not o then return nil end
    local f = o[name]
    if type(f) ~= "function" then return nil end
    return safe(f, o, ...)
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "trinket", fmt, ...) end
end

local function read_slot(p, slot)
    local row = m(p, "get_item_at_inventory_slot", slot)
    local obj = type(row) == "table" and row.object or nil
    local id = tonumber(m(obj, "get_item_id")) or 0
    if id <= 0 then return false end
    local sp = safe(function() return core.quests.get_item_spell(id) end)
    local sid = type(sp) == "table" and tonumber(sp.spell_id) or 0
    local sname = type(sp) == "table" and type(sp.spell_name) == "string" and sp.spell_name or ""
    if (sid or 0) <= 0 and sname == "" then return false end          -- passive: never pressed
    local name = m(obj, "get_name")
    if type(name) ~= "string" or name == "" then name = "item " .. id end
    return { id = id, name = name, spell = sname, spell_id = sid }
end

--- Re-read both slots (at most every SCAN_GAP s).
function T.scan(p, t)
    t = t or now()
    if not p or (t - last_scan) < T.SCAN_GAP then return end
    last_scan = t
    for _, slot in ipairs(T.SLOTS) do info[slot] = read_slot(p, slot) end
end

--- The on-use trinket in `slot` ({ id, name, spell }) or nil.
function T.at(slot) return info[slot] or nil end

local function enabled(slot)
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return false end
    return gui.is_on(T.KEYS[slot]) == true
end

local function pct(u)
    local v = tonumber(m(u, "get_health_percentage"))
    if v then return v end
    local h, mx = tonumber(m(u, "get_health")), tonumber(m(u, "get_max_health"))
    if h and mx and mx > 0 then return h / mx * 100 end
    return nil
end

local function worth_it(p, target, ctx)
    local my = pct(p)
    if my and my < T.LOW_HP then return true end
    local n = (type(ctx) == "table" and type(ctx.enemies) == "table") and #ctx.enemies or 0
    if n >= 2 then return true end
    local th = pct(target)
    return th == nil or th > T.MIN_TARGET_HP
end

--- In a fight: press a ticked, ready on-use trinket. True when one was used.
function T.tick(p, target, ctx)
    if not p or not target then return false end
    local t = now()
    T.scan(p, t)
    if m(p, "is_in_combat") ~= true or m(p, "is_mounted") == true or m(p, "is_dead") == true then return false end
    if m(target, "is_dead") == true then return false end
    for _, slot in ipairs(T.SLOTS) do
        local tr = info[slot]
        if tr and t >= next_try[slot] and enabled(slot) then
            next_try[slot] = t + T.USE_GAP
            local cd = tonumber(m(p, "get_item_cooldown", tr.id))
            if (cd == nil or cd <= 0) and worth_it(p, target, ctx) then
                local okc, sc = pcall(require, "spellcheck")
                local used = okc and type(sc) == "table" and type(sc.use_item) == "function"
                    and sc.use_item(tr.id, { skip_moving = true }) == true
                if used then
                    if (logged[slot] or -1e9) + 10 < t then
                        logged[slot] = t
                        trail("used %s (slot %d, %s)", tr.name, slot, tr.spell ~= "" and tr.spell or "on use")
                    end
                    return true
                end
                next_try[slot] = t + T.RETRY
            end
        end
    end
    return false
end

function T._reset()
    info, last_scan, next_try, logged = { [13] = false, [14] = false }, -1e9, { [13] = 0, [14] = 0 }, {}
end

return T
