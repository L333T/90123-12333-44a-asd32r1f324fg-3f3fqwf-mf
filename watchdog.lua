-- ============================================================================
-- Master Farmer - Grindbot
-- NPC-stuck watchdog
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.225.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY NOT A GAME RELOAD
--   The Sylvanas API has no way to reload the UI or restart the client - no
--   reload, restart, logout, macro or console command, and no plugin reload.
--   So this does what a reload would do for the BOT: throw away every piece
--   of NPC-interaction state it holds and walk away from the NPC.
--
-- STUCK MEANS
--   Continuously "at an NPC" for STUCK_AFTER seconds: an NPC window open
--   (gossip, merchant, trainer, quest dialog), a vendor trip under way, or the
--   quest engine working an accept / turn in / talk goal. A gap shorter than
--   GAP_FORGIVE does not restart the clock - dialogs flicker between frames.
--
-- RECOVERY
--   Close the gossip, quest and loot frames; clear the target; reset the
--   vendor, trainer, loot and quest-dialog state; count the current quest
--   goal as done so it is not walked straight back into; walk WALK_AWAY
--   yards off (which also makes the game close a merchant or trainer
--   window). If that happens MAX_RECOVERIES times inside RECOVERY_WINDOW,
--   the bot is stopped instead of looping, and the log says why.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local state = require("state")

local watchdog = {}

local STUCK_AFTER = 300.0     -- 5 minutes
local GAP_FORGIVE = 10.0      -- seconds not at an NPC before the clock resets
local WALK_AWAY = 20
local MAX_RECOVERIES = 3
local RECOVERY_WINDOW = 900.0 -- 15 minutes

local since = 0               -- when the current NPC stretch began
local last_seen = 0           -- last tick that looked like an NPC interaction
local recoveries = {}         -- times of recent recoveries

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then
        return res
    end
    return nil
end

local function req(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

--- A module only if something already loaded it. The quest pack is loaded
--- lazily; requiring it from here in grind mode would load it for nothing.
local function loaded(name)
    local m = package.loaded[name]
    if type(m) == "table" then
        return m
    end
    return nil
end

local function log(fmt, ...)
    local text = string.format(fmt, ...)
    pcall(function() core.log_warning("[Master Farmer - Grindbot] " .. text) end)
    local elog = req("errorlog")
    if elog and type(elog.warn) == "function" then
        elog.warn("%s", text)
    end
end

--- Does this tick look like the bot is at an NPC?
local function at_npc()
    if safe(function() return core.quests.is_gossip_frame_shown() end) == true then
        return true
    end
    local vendor = req("vendor")
    if vendor then
        if type(vendor.merchant_open) == "function" and vendor.merchant_open() == true then
            return true
        end
        if type(vendor.is_busy) == "function" and vendor.is_busy() == true then
            return true
        end
    end
    local n = safe(function() return core.quests.get_num_trainer_services() end)
    if type(n) == "number" and n > 0 then
        return true
    end
    local quest = loaded("quest/engine")
    if quest and type(quest.in_npc_interaction) == "function" and quest.in_npc_interaction() then
        return true
    end
    return false
end

local function walk_away(player)
    local me = safe(function() return player:get_position() end)
    if not me then
        return
    end
    local ang = (safe(function() return player:get_rotation() end) or 0) + math.pi
    local vec3 = req("common/geometry/vector_3")
    local movement = req("movement")
    if not vec3 or not movement or type(movement.nav_to) ~= "function" then
        return
    end
    local spot = vec3.new(me.x + math.cos(ang) * WALK_AWAY, me.y + math.sin(ang) * WALK_AWAY, me.z)
    if type(movement.nav_stop) == "function" then
        movement.nav_stop()
    end
    movement.nav_to(spot, true)
end

local function stop_bot()
    local gui = req("gui")
    if gui and type(gui.stop) == "function" then
        gui.stop()
    end
end

local function recover(player, now)
    -- Forget recoveries older than the window, then count this one.
    local keep = {}
    for i = 1, #recoveries do
        if (now - recoveries[i]) < RECOVERY_WINDOW then
            keep[#keep + 1] = recoveries[i]
        end
    end
    keep[#keep + 1] = now
    recoveries = keep

    log("Stuck at an NPC for %d minutes - resetting NPC state and walking away (%d in the last %d min).",
        math.floor(STUCK_AFTER / 60), #recoveries, math.floor(RECOVERY_WINDOW / 60))

    pcall(function() core.quests.close_gossip() end)
    pcall(function() core.quests.close_quest() end)
    pcall(function() core.input.close_loot() end)
    state.reset_target()

    local vendor = req("vendor")
    if vendor and type(vendor.reset) == "function" then pcall(vendor.reset) end
    local trainer = req("trainer")
    if trainer and type(trainer.reset) == "function" then pcall(trainer.reset) end
    local loot = req("loot")
    if loot and type(loot.reset) == "function" then pcall(loot.reset) end
    local npc = loaded("quest/npc")
    if npc and type(npc.close) == "function" then pcall(npc.close) end
    local quest = loaded("quest/engine")
    if quest and type(quest.skip_current_goal) == "function" then pcall(quest.skip_current_goal) end

    if #recoveries >= MAX_RECOVERIES then
        log("Stuck at an NPC %d times in %d minutes - stopping the bot.",
            #recoveries, math.floor(RECOVERY_WINDOW / 60))
        recoveries = {}
        stop_bot()
        return
    end
    walk_away(player)
    state.set_note("Watchdog", "Was stuck at an NPC - reset and walked away")
end

-- ----------------------------------------------------------------------------
-- STUCK TRAVELLING -> HEARTHSTONE (2.45.0)
-- ----------------------------------------------------------------------------
-- Travelling (the quest engine walking to a waypoint, or navigation moving
-- the character) for TRAVEL_STUCK seconds without getting TRAVEL_PROGRESS
-- yards from where the stretch began. Fights, rests, loot and NPC visits are
-- not travel and restart the clock. The fix is Hearthstone 6948: stop, cast
-- (10 s), and hold every tick for HEARTH_HOLD so nothing moves the character
-- and cancels it; the guide re-routes from home. With the stone on cooldown
-- or missing, log it, walk off 20 yd to try another line, and start again.
local HEARTHSTONE = 6948
local TRAVEL_STUCK = 300.0
local TRAVEL_PROGRESS = 20
local HEARTH_HOLD = 12.0
local travel_since = 0
local travel_anchor = nil
local hearth_until = 0

local function travelling()
    local quest = loaded("quest/engine")
    if quest and type(quest.in_travel) == "function" and quest.in_travel() then
        return true
    end
    local movement = req("movement")
    return movement and type(movement.is_navigating) == "function" and movement.is_navigating() == true
end

local function use_hearthstone(player)
    local item = safe(function() return izi.item(HEARTHSTONE) end)
    if not item then
        return false, "no hearthstone API"
    end
    if safe(function() return item:in_inventory() end) ~= true then
        return false, "Hearthstone is not in the bags"
    end
    if safe(function() return item:cooldown_up() end) == false then
        local left = safe(function() return item:cooldown_remains() end)
        return false, string.format("Hearthstone on cooldown (%s s)", tostring(left and math.floor(left) or "?"))
    end
    local movement = req("movement")
    if movement and type(movement.nav_stop) == "function" then
        movement.nav_stop()
    end
    local ok = safe(function() return item:use_self("Hearthstone - stuck travelling") end) == true
    if not ok then
        ok = safe(function() return item:use_self_safe("Hearthstone - stuck travelling") end) == true
    end
    return ok, ok and nil or "Hearthstone use was refused"
end

local function travel_tick(player, now)
    -- A hearth cast in progress: stand still until it has had time to land.
    if now < hearth_until then
        -- A fight ends the hold (2.217.0): it claimed the tick for 12 s ahead
        -- of everything, so the bot stood still while something hit it. Combat
        -- breaks the cast anyway; the stuck timer below starts over.
        local targeting = req("targeting")
        local attacked = targeting and type(targeting.attackers) == "function"
            and targeting.attackers(player) > 0
        if attacked or safe(function() return player:is_in_combat() end) == true then
            hearth_until = 0
            travel_since, travel_anchor = 0, nil
            return false
        end
        local movement = req("movement")
        if movement and type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
        state.set_note("Watchdog", "Hearthstone - stuck travelling")
        return true
    end
    local in_combat = safe(function() return player:is_in_combat() end) == true
    if in_combat or not travelling() then
        travel_since, travel_anchor = 0, nil
        return false
    end
    local pos = safe(function() return player:get_position() end)
    if not pos then
        return false
    end
    if travel_since == 0 or not travel_anchor then
        travel_since, travel_anchor = now, { x = pos.x, y = pos.y }
        return false
    end
    local dx, dy = pos.x - travel_anchor.x, pos.y - travel_anchor.y
    if dx * dx + dy * dy >= TRAVEL_PROGRESS * TRAVEL_PROGRESS then
        travel_since, travel_anchor = now, { x = pos.x, y = pos.y }
        return false
    end
    if (now - travel_since) < TRAVEL_STUCK then
        return false
    end
    travel_since, travel_anchor = 0, nil
    local ok, why = use_hearthstone(player)
    if ok then
        log("Stuck travelling to a waypoint for %d minutes - using the Hearthstone.", math.floor(TRAVEL_STUCK / 60))
        hearth_until = now + HEARTH_HOLD
        state.set_note("Watchdog", "Hearthstone - stuck travelling")
        return true
    end
    log("Stuck travelling to a waypoint for %d minutes, and %s - walking off to try another line.",
        math.floor(TRAVEL_STUCK / 60), tostring(why))
    walk_away(player)
    return true
end

--- Called once per bot tick while the bot is running.
function watchdog.tick(player)
    if not player then
        return false
    end
    local now = izi.now()
    if travel_tick(player, now) then
        return true
    end
    if at_npc() then
        if since == 0 or (now - last_seen) > GAP_FORGIVE then
            since = now
        end
        last_seen = now
        if (now - since) >= STUCK_AFTER then
            since = 0
            recover(player, now)
            return true
        end
    elseif since ~= 0 and (now - last_seen) > GAP_FORGIVE then
        since = 0
    end
    return false
end

--- Forget the current stretch (bot stopped or restarted).
function watchdog.reset()
    since, last_seen = 0, 0
    travel_since, travel_anchor, hearth_until = 0, nil, 0
end

return watchdog
