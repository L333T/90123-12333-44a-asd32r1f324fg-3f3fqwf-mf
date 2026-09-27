-- ============================================================================
-- Master Farmer - Grindbot
-- NPC-stuck watchdog
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.44.0
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

--- Called once per bot tick while the bot is running.
function watchdog.tick(player)
    if not player then
        return false
    end
    local now = izi.now()
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
end

return watchdog
