-- ============================================================================
-- Master Farmer - Grindbot
-- Main — update cascade
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.200.0
-- Folder: Master_Farmer_Grindbot
-- Standalone IZI. movement.lua is a single-owner state machine: simple_movement
-- drives all travel and combat repositioning, Sentinel is the navmesh fallback
-- for long/blocked out-of-combat legs, movement_handler does facing and cast
-- pauses only. Nothing else in the plugin issues a movement command.
-- No FB_Nexus. No NavLib.
-- Tick: death -> rest -> loot -> buffs -> train -> vendor -> equip -> grind XOR quest (Start gated)
-- ============================================================================

local PLUGIN_MODULES = {
    "spellbook",
    "spell_range",
    "geometry",
    "auras",
    "picks",
    "combat",
    "conjure",
    "quest/guide",
    "debuglog",
    "errorlog",
    "watchdog",
    "bags",
    "pets",
    "ui",
    "version",
    "state",
    "modes",
    "path_format",
    "data/consumables",
    "loader",
    "gui",
    "targeting",
    "movement",
    "loot",
    "path_runner",
    "rotations/mage",
    "rotations/warrior",
    "rotation",
    "death",
    "healing",
    "vendor",
    "gossip",
    "supplies",
    "equip",
    "trainer",
    "resting",
    "racials",
    "data/racials",
    "data/factions",
    "events",
    "buffs",
    "smart",
    "data/class_spells",
    "settings",
    "data/spell_categories",
    -- The path INDEXES. These were missing, and the effect was invisible and
    -- very confusing: a reload reused the previous session's grind/catalog
    -- table, so a newly added route list never appeared in the menu however
    -- many times the plugin was reloaded. They are index tables of a few
    -- kilobytes, so dropping them costs nothing.
    "grind/catalog",
    "grind/paths/ally160/catalog",
}

for i = 1, #PLUGIN_MODULES do
    package.loaded[PLUGIN_MODULES[i]] = nil
end

---@type izi_api
local izi = require("common/izi_sdk")

local identity = require("version")

-- First, so everything after it can be guarded. Required with pcall: a
-- logger that fails to load must not take the plugin with it.
local errorlog = nil
do
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then
        errorlog = mod
        errorlog.start(identity.version)
    end
end

--- A flight-recorder probe point (see errorlog.lua). Free when not armed.
local function probe(tag)
    if errorlog then
        errorlog.probe(tag)
    end
end

--- Run fn under the error log, or under a bare pcall without one.
local function guarded(where, fn, ...)
    if errorlog then
        return errorlog.guard(where, fn, ...)
    end
    return pcall(fn, ...)
end

_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}
local NS = _G.MasterFarmer_Grindbot
NS.meta = NS.meta or {
    name = identity.name,
    version = identity.version,
    author = identity.authors,
}
NS._sessions = NS._sessions or {}
if type(NS._sessions[identity.folder]) ~= "number" then
    NS._sessions[identity.folder] = 1
end
local MY_SESSION = NS._sessions[identity.folder]

local function is_stale()
    return NS._sessions[identity.folder] ~= MY_SESSION
end

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function load_mod(name)
    local ok, mod = pcall(require, name)
    if ok then
        return mod
    end
    core.log_error("[Master Farmer - Grindbot] require failed (" .. name .. "): " .. tostring(mod))
    if errorlog then
        errorlog.error("require " .. name, mod)
    end
    return nil
end

local gui = load_mod("gui")
if not gui then
    core.log_error("[Master Farmer - Grindbot] GUI module failed - window will not appear.")
else
    core.register_on_render_window_callback(function()
        if is_stale() then
            return
        end
        probe("gui.draw")
        guarded("gui.draw", gui.draw)
        probe("-")
    end)
    core.log(string.format("[Master Farmer - Grindbot] v%s GUI ready", identity.version))
end

local state = load_mod("state")
local spellbook = load_mod("spellbook")
local targeting = load_mod("targeting")
local movement = load_mod("movement")
local loot = load_mod("loot")
local rotation = load_mod("rotation")
local death = load_mod("death")
local healing = load_mod("healing")
local conjure = load_mod("conjure")
local picks = load_mod("picks")
local vendor = load_mod("vendor")
local equip = load_mod("equip")
local trainer = load_mod("trainer")

-- Game events. Registered once per SESSION, not once per load: the callback
-- cap is per plugin and this file re-runs on every hot reload. events.install
-- keeps the guard on the shared namespace and refreshes the handler table, so
-- a reload picks up new handler code without registering a second callback.
local buffs = load_mod("buffs")
local pets = load_mod("pets")
local debuglog = load_mod("debuglog")
local settings = load_mod("settings")

-- What gets remembered per character.
--
-- Only state held in plain Lua tables is registered here. Every core.menu
-- element already persists against its own id, so a checkbox or slider
-- written here would be stored twice and the two copies would disagree the
-- moment one of them changed.
if settings then
    -- The route as an ID, not an index. An index means a different route
    -- after the catalog gains entries or the faction changes.
    settings.register("route",
        function()
            return gui and type(gui.selected_route_id) == "function" and gui.selected_route_id() or nil
        end,
        function(value)
            if gui and type(gui.select_route_id) == "function" then
                gui.select_route_id(value)
            end
        end)

    -- The Spells tab picks - buff toggles and rotation choices alike. These
    -- only exist after the spellbook scan and so could never have had a menu
    -- element behind them. The key stays "buffs" so a settings file written
    -- by 2.3.0 still loads; picks.deserialise reads that older one-line form
    -- as "these were all switched on", which is what it meant.
    settings.register("buffs",
        function()
            return picks and type(picks.serialise) == "function" and picks.serialise() or nil
        end,
        function(value)
            if picks and type(picks.deserialise) == "function" then
                picks.deserialise(value)
            end
        end)

    -- Quest givers learned at a gossip frame, kept per character so an NPC
    -- met in one session is known in the next. Required lazily: quest/guide
    -- is only meaningful when the guide addon is present, and main should not
    -- fail to load because it is not.
    settings.register("npc_ids",
        function()
            local ok, guide = pcall(require, "quest/guide")
            if ok and guide and type(guide.serialise) == "function" then
                return guide.serialise()
            end
            return nil
        end,
        function(value)
            local ok, guide = pcall(require, "quest/guide")
            if ok and guide and type(guide.deserialise) == "function" then
                guide.deserialise(value)
            end
        end)
end
local events = load_mod("events")
if events and type(events.install) == "function" then
    pcall(events.install)
end
local supplies = load_mod("supplies")
local loader = load_mod("loader")
local path_runner = load_mod("path_runner")
local modes = load_mod("modes")

if gui and supplies and type(supplies.register_gui) == "function" then
    pcall(supplies.register_gui, gui.get_menu())
end

if gui and trainer and type(trainer.register_gui) == "function" then
    pcall(trainer.register_gui, gui.get_menu())
end
if gui and equip and type(equip.register_gui) == "function" then
    pcall(equip.register_gui, gui.get_menu())
end

-- The class and racial checkboxes are gone (2.64.0): the Spells tab lists
-- the known class spells and racials itself, and smart.lua builds the
-- rotation from the ones ticked there.
local racials = load_mod("racials")

local nav_halted = false
local move_debug_on = false

local function halt_bot_movement()
    if nav_halted then
        return
    end
    nav_halted = true
    if path_runner then
        path_runner.stop()
    end
    if movement then
        movement.halt()
    end
end

local function allow_bot_movement()
    nav_halted = false
end

local function pause_path_for_combat()
    if type(path_runner.is_paused) ~= "function" or path_runner.is_paused() ~= true then
        path_runner.pause()
    end
end

local function rotation_yards(player)
    local yards = 30
    if rotation and type(rotation.combat_range) == "function" then
        yards = rotation.combat_range(player)
    end
    if type(yards) ~= "number" or yards < 1 then
        yards = 30
    end
    return yards
end

--- How far out to look for something to fight.
---
--- The class decides: melee scans tighter than a caster, because melee has to
--- close the distance and then stand still, and every extra mob inside the
--- scan is one more thing arriving during that. The path may ask for a wider
--- scan through its `pull` value, and that still wins - a route author who
--- says "pull from 50 yards here" knows the terrain better than the class
--- default does.
local function scan_yards(player)
    local yards = 30
    if rotation and type(rotation.scan_range) == "function" then
        local ok, n = pcall(rotation.scan_range, player)
        if ok and type(n) == "number" and n >= 5 then
            yards = n
        end
    end
    local current = path_runner.current_path and path_runner.current_path() or nil
    local pull = current and tonumber(current.pull)
    if type(pull) == "number" and pull > yards then
        yards = pull
    end
    if yards > 80 then
        yards = 80
    end
    return yards
end

local function unit_has_los(player, unit)
    local los = safe(function() return player:los_to(unit) end)
    if los == true then
        return true
    end
    return los ~= false
end

local function in_rotation_range(player, unit, yards)
    if not player or not unit then
        return false
    end
    yards = yards or rotation_yards(player)
    local in_range = safe(function() return unit:is_in_range(yards) end)
    if in_range ~= true then
        local d = safe(function() return player:distance_to(unit) end)
        if type(d) ~= "number" or d > yards then
            return false
        end
    end
    return unit_has_los(player, unit)
end

local function closest_in_range(player, lists, yards)
    local found = {}
    if type(lists) ~= "table" then
        return nil
    end
    for i = 1, #lists do
        local list = lists[i]
        if type(list) == "table" then
            for j = 1, #list do
                local u = list[j]
                if u and in_rotation_range(player, u, yards) then
                    found[#found + 1] = u
                end
            end
        end
    end
    return targeting.nearest(player, found)
end

--- `pack` is optional. When the caller has already scanned with this same
--- range in this same frame it passes its list in, and this does not scan a
--- second time. Omitting it keeps the old behaviour exactly, so the function
--- still stands on its own.
local function path_fight(player, unit, scan_range, pack)
    if movement.needs_rejoin() == true then
        -- Getting back on the recorded line outranks fighting from off it, so
        -- hand movement back to navigation before asking for the rejoin hop -
        -- otherwise combat ownership would refuse it until the fight ended.
        movement.combat_release()
        if movement.is_moving() then
            movement.nav_stop()
        else
            movement.rejoin_path()
        end
        targeting.set_current(unit, "kill")
        targeting.start_auto_attack(player, unit)
        state.set_note("Path", "Rejoin path")
        return true
    end
    pause_path_for_combat()
    targeting.set_current(unit, "kill")
    targeting.start_auto_attack(player, unit)

    -- Combat movement owns the player from here: it faces the target, holds the
    -- rotation's range band and kites when the class profile asks for it. The
    -- path leash keeps every combat hop within PATH_LEASH of the recorded line,
    -- so the bot fights from the path instead of wandering off it.
    local yards = rotation_yards(player)
    movement.combat_engage(player, unit, yards)

    -- Reuse the caller's scan when there is one. Two combat_scan calls in one
    -- frame with the same player and range cannot disagree: the world does not
    -- change between them, and unit_helper:get_enemy_list_around is cached by
    -- the core anyway, so the second call was re-filtering an identical list
    -- into a second identical table.
    if type(pack) ~= "table" then
        pack = targeting.combat_scan(player, scan_range)
    end
    state.set_note("Path", "Combat")
    rotation.tick(player, unit, { enemies = pack, no_move = true })
    return true
end

local function path_handle_combat(player)
    if not player or not targeting or not rotation or not path_runner then
        return false
    end
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        pause_path_for_combat()
        if movement and type(movement.is_moving) == "function" and movement.is_moving() then
            movement.nav_stop()
        end
        pcall(function()
            core.input.stop_attack()
        end)
        return true
    end
    local want_pull = gui.is_on("path_combat")
    local want_back = gui.is_on("fight_back")
    if want_pull ~= true and want_back ~= true then
        if path_runner.is_paused() then
            path_runner.resume()
        end
        return false
    end

    -- The class sets the scan; combat_range is a floor, because a scan
    -- narrower than the range the rotation actually fights at would mean
    -- walking past things it could already hit.
    local range = scan_yards(player)
    local yards = rotation_yards(player)
    if range < yards then
        range = yards
    end
    local now = izi.now()
    local unit = state.target.unit
    if unit and safe(function() return unit:is_valid() end) == true then
        if now > (state.grind.black_until or 0) and state.target.kind == "kill" then
            state.mark_killed(state.target.guid)
            state.reset_target()
            unit = nil
        end
    else
        unit = nil
        if state.target.unit then
            state.reset_target()
        end
    end

    if unit then
        if safe(function() return unit:is_dead_or_ghost() end) == true or safe(function() return unit:is_dead() end) == true then
            state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
            if loot and type(loot.note_kill) == "function" then
                loot.note_kill(unit)
            end
            movement.nav_stop()
            if type(movement.combat_release) == "function" then
                movement.combat_release()
            end
            state.reset_target()
            unit = nil
        else
            if not in_rotation_range(player, unit, yards) then
                state.reset_target()
                unit = nil
            end
        end
    end

    local pack = targeting.combat_scan(player, range)
    local pull = {}
    if want_pull == true then
        local current = path_runner.current_path and path_runner.current_path() or nil
        local mobs = current and current.mobs or nil
        pull = targeting.find_mobs(player, mobs, range, true, { skip_reach = true })
    elseif want_back == true then
        local in_combat = safe(function() return player:is_in_combat() end) == true
        if in_combat ~= true then
            if path_runner.is_paused() then
                if not movement.in_combat_movement() then
                    if type(movement.combat_release) == "function" then
                        movement.combat_release()
                    end
                    if movement.can_navigate() then
                        path_runner.resume()
                    end
                end
            end
            return false
        end
    end

    local target = closest_in_range(player, { pack, pull }, yards)
    if not target and unit and in_rotation_range(player, unit, yards) then
        target = unit
    end
    if target then
        state.grind.black_until = now + gui.slider("max_kill", 60)
        if movement.sentinel_active and movement.sentinel_active() then
            movement.nav_stop()
        end
        return path_fight(player, target, range, pack)
    end

    if path_runner.is_paused() then
        if movement.can_navigate() then
            if type(movement.combat_release) == "function" then
                movement.combat_release()
            end
            path_runner.resume()
        elseif not movement.in_combat_movement() then
            path_runner.resume()
        end
    end
    return false
end

local function player_is_busy(player)
    if not player then
        return false
    end
    if safe(function() return player:is_channeling_or_casting() end) == true then
        return true
    end
    if safe(function() return player:is_casting_spell() end) == true then
        return true
    end
    if safe(function() return player:is_casting() end) == true then
        return true
    end
    if safe(function() return player:is_channeling() end) == true then
        return true
    end
    return false
end

local function tick_rotation_only(player)
    if not player or not rotation then
        return
    end

    -- The same guard the Play path has had all along.
    --
    -- That check lives at the bottom of on_update, AFTER this branch returns,
    -- so Rotation Only never had it: the rotation was driven every single
    -- frame whether or not a cast was already in flight. On an instant-cast
    -- class that is merely wasteful; on a caster it is fatal, because
    -- Frostbolt takes seconds and the next frame started the decision over
    -- before it could land. "The rotation does not run" is what a caster that
    -- never finishes a cast looks like.
    -- Dead is the one thing that stops Rotation Only outright. Everything
    -- else - no target, out of combat, standing still - is a normal state in
    -- which buffs should still be kept up.
    if safe(function() return player:is_dead_or_ghost() end) == true
        or safe(function() return player:is_dead() end) == true then
        state.set_note("Rotation", "Rotation Only - dead")
        return
    end

    if player_is_busy(player) then
        state.set_note("Rotation", "Rotation Only - casting")
        return
    end

    -- Buff upkeep runs BEFORE the target check, and therefore with or without
    -- an enemy selected.
    --
    -- buffs.lua has always returned true from bot_is_working() when
    -- rotation_only is set - it was written expecting to be called here. It
    -- never was: on_update returns at the Rotation Only branch, and
    -- buffs.tick sits below that, in the Play path. So a Mage in Rotation
    -- Only kept no Armour, no Arcane Intellect and no Mana Shield unless it
    -- happened to have an enemy targeted, and out of combat nothing ran at
    -- all.
    --
    -- Returning after a cast is the same one-action-per-tick rule the rest of
    -- the cascade follows; the buff has a global cooldown to serve.
    if buffs and type(buffs.tick) == "function" and buffs.tick(player) then
        state.set_note("Rotation", "Rotation Only - buffing")
        return
    end
    if rotation.buffs_ooc(player) then
        state.set_note("Rotation", "Rotation Only - buffing")
        return
    end

    local target = safe(function() return player:get_target() end)
    if not target or safe(function() return target:is_valid() end) ~= true then
        state.set_note("Rotation", "Rotation Only - buffs up, select a target")
        return
    end
    if safe(function() return target:is_dead_or_ghost() end) == true or safe(function() return target:is_dead() end) == true then
        state.set_note("Rotation", "Rotation Only - target dead")
        return
    end
    -- Only assert the target when it is not already ours. This ran every
    -- tick on the unit the player had just been read FROM, so it was at best
    -- redundant and at worst a re-target that clipped the cast it had started
    -- the frame before.
    local have = safe(function() return player:get_target() end)
    local same = false
    if have then
        local a = safe(function() return have:get_guid() end)
        local b = safe(function() return target:get_guid() end)
        same = (a ~= nil and a == b)
    end
    if not same then
        pcall(function()
            core.input.set_target(target)
        end)
    end

    local pack = {}
    if targeting then
        pack = targeting.combat_scan(player, scan_yards(player))
    end
    state.set_note("Rotation", "Rotation Only")
    rotation.tick(player, target, { enemies = pack, no_move = true })
end

-- Incremental collection help, every frame. The host's collector runs on
-- its own schedule; a small step here keeps the heap near what is actually
-- live instead of letting a frame's garbage pile up until the next cycle.
-- Cheap: a step this size does a little marking and sweeping, never a full
-- collection.
local GC_STEP = 16

-- BOT TICK (2.28.0). The Plugin Monitor put Master Farmer at 93 ms of Lua time
-- a frame. Every frame ran the whole decision cascade - death, conjure,
-- healing, the loot scan, buffs, trainer, vendor, equip, then the mode tick
-- with its target scans, combat movement and the class rotation - dozens of
-- native calls and object scans, 60+ times a second, for decisions a bot
-- needs about ten times a second. The cascade now runs every BOT_TICK
-- seconds. What must stay per frame stays per frame: the stale check, izi's
-- own update, keybinds, and movement.pulse, which drives the walker smoothly
-- between decisions.
local BOT_TICK = 0.1
local next_bot_tick = 0

-- ============================================================================
-- PERIODIC UI RELOAD (2.189.0)
-- ============================================================================
-- While the bot is running, core.reload_game_ui() every RELOAD_EVERY seconds
-- - at a safe moment only: never in combat, casting, resting, looting, at a
-- vendor / trainer / NPC window, dead, on a flight, or with a live kill
-- target. The timer starts with Start and restarts after each reload; Stop
-- clears it. Guarded like the reload on landing (2.107.0).
local RELOAD_EVERY = 1800
local reload_since = nil

local function reload_safe(player)
    if type(core.reload_game_ui) ~= "function" then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    if safe(function() return player:is_dead_or_ghost() end) == true then return false end
    if safe(function() return player:is_channeling_or_casting() end) == true then return false end
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then return false end
    if loot and type(loot.has_work) == "function" and loot.has_work(player) then return false end
    if vendor and type(vendor.is_busy) == "function" and vendor.is_busy() then return false end
    if vendor and type(vendor.merchant_open) == "function" and vendor.merchant_open() then return false end
    if trainer and type(trainer.busy) == "function" and trainer.busy() then return false end
    if safe(function() return core.quests.is_gossip_frame_shown() end) == true then return false end
    local tgt = state and state.target and state.target.unit
    if tgt and state.target.kind == "kill" and safe(function() return tgt:is_valid() end) == true
        and safe(function() return tgt:is_dead() end) ~= true then
        return false
    end
    return true
end

--- True when it reloaded this tick.
local function periodic_reload(player, now_t)
    if reload_since == nil then
        reload_since = now_t
        return false
    end
    if (now_t - reload_since) < RELOAD_EVERY or not reload_safe(player) then
        return false
    end
    reload_since = now_t
    if errorlog and type(errorlog.info) == "function" then
        pcall(errorlog.info, "Periodic UI reload (every %d min)", math.floor(RELOAD_EVERY / 60))
    end
    pcall(core.reload_game_ui)
    return true
end

local function on_update()
    if is_stale() then
        return
    end
    probe("u:begin")
    if errorlog then
        errorlog.frame()
    end
    pcall(collectgarbage, "step", GC_STEP)
    if errorlog then
        errorlog.tick(safe(function() return izi.now() end))
    end
    probe("u:izi.on_update")
    pcall(function()
        izi.on_update()
    end)
    if not gui then
        return
    end
    probe("u:keybinds")
    gui.process_keybinds()
    if movement then
        local want_debug = gui.is_on("move_debug") == true
        if want_debug ~= move_debug_on then
            move_debug_on = want_debug
            movement.set_debug(want_debug)
        end
        -- The movement state machine ticks before anything else reads its state,
        -- so every consumer this frame sees one consistent owner and state.
        probe("u:movement.pulse")
        pcall(movement.pulse)
    end
    -- 2.198.0: the loot burst runs every frame (attempts one frame apart).
    if loot and type(loot.frame) == "function" then
        probe("u:loot.frame")
        pcall(loot.frame)
    end

    -- Everything below is a decision, and decisions run at BOT_TICK.
    local now_t = safe(function() return izi.now() end) or 0
    if now_t < next_bot_tick and (next_bot_tick - now_t) <= BOT_TICK then
        probe("-")
        return
    end
    next_bot_tick = now_t + BOT_TICK
    if errorlog then
        errorlog.tick_begin()
    end

    local player = safe(function() return izi.me() end)
    if not player or safe(function() return player:is_valid() end) ~= true then
        return
    end
    gui.sync_player(player)
    -- Load once for this character, then flush changes on a debounce. Runs
    -- before the cascade so a restored route is in place for the first tick
    -- that could use it.
    probe("u:settings")
    if settings and type(settings.tick) == "function" then
        pcall(settings.tick, player)
    end
    if targeting then
        targeting.cache_player(player)
    end

    if spellbook then
        spellbook.tick()
        if not spellbook.ready() then
            local left = spellbook.wait_left()
            if state then
                state.set_note("Load", string.format("Waiting for spellbook  %.1fs", left))
            end
            return
        end
    end

    if gui.is_on("rotation_only") then
        halt_bot_movement()
        if vendor then
            vendor.reset()
        end
        tick_rotation_only(player)
        return
    end

    -- Questing enabled: keep the guide snapshot current from here, the update
    -- callback, so the Questing tab has live data without reading RestedXP
    -- from the render hook - started or not.
    if modes and gui.mode() == modes.QUEST then
        local ok_g, g = pcall(require, "quest/guide")
        if ok_g and type(g) == "table" and type(g.update) == "function" then
            pcall(g.update)
        end
    end

    if not gui.is_started() then
        reload_since = nil            -- 2.189.0: the reload timer starts with Start
        halt_bot_movement()
        if vendor then
            vendor.reset()
        end
        -- The spellbook wait is the last note written before this return.
        -- Once the scan has finished, leave it there and the status line
        -- stays on "Waiting for spellbook  0.0s" for the whole idle session.
        if state and state.note_head == "Load" then
            state.set_note("Idle", "Idle")
        end
        return
    end
    allow_bot_movement()

    -- NPC-stuck watchdog: 5 minutes at an NPC resets all NPC state and walks
    -- away (the API cannot reload the game). It claims the tick it acts on.
    local ok_w, watchdog = pcall(require, "watchdog")
    if ok_w and type(watchdog) == "table" and type(watchdog.tick) == "function"
        and watchdog.tick(player) then
        return
    end
    if not state or not movement or not death or not rotation or not healing then
        return
    end

    probe("u:death")
    if death.tick(player) then
        return
    end
    -- On a flight path (2.95.0): nothing to steer, fight or loot until it lands.
    -- 2.106.0: also the quest engine's own flight tracking (position based),
    -- since is_flying is not proven true on a taxi.
    local on_flight = safe(function() return player:is_flying() end) == true
    if not on_flight then
        local qe = package.loaded["quest/engine"]
        if type(qe) == "table" and type(qe.in_flight) == "function" then
            on_flight = safe(function() return qe.in_flight(player) end) == true
        end
    end
    if on_flight then
        state.set_note("Travel", "On a flight")
        return
    end
    probe("u:reload")
    if periodic_reload(player, now_t) then
        return
    end
    -- The 360-degree enemy scan (2.95.0): attack list + avoid list / danger map.
    if targeting and type(targeting.scan_enemies) == "function" then
        pcall(targeting.scan_enemies, player)
    end
    -- Rest outranks looting. Looting used to come first, and because
    -- loot.tick returns true on every tick while a lootable corpse is in
    -- range, healing.tick was never reached - the bot would sit at 30% mana
    -- working through corpses and never drink. Resting also hard-locks
    -- movement, so loot.tick below cannot walk off mid-drink.
    -- Ahead of healing on purpose. A mage with an empty bag needs to conjure
    -- BEFORE the rest logic goes looking for water, or the rest finds nothing,
    -- reports empty bags, and the bot stands at low mana next to a spell that
    -- would have fixed it. conjure.tick refuses to fire mid-meal, so it cannot
    -- interrupt a rest that is already under way.
    -- LOOT FIRST (2.46.0): once a mob is dead its corpse is looted before
    -- any other action - conjuring, eating and drinking, buffs, trainer,
    -- vendor, equip, the next pull. loot.tick still steps aside for anything
    -- attacking the player.
    probe("u:loot")
    if loot and loot.tick(player) then
        return
    end
    probe("u:conjure")
    if conjure and type(conjure.tick) == "function" and conjure.tick(player) then
        return
    end
    probe("u:healing")
    -- REST PROBE (2.193.0): time this call; a slow one writes a SPIKE line.
    if errorlog and type(errorlog.spike_begin) == "function" then errorlog.spike_begin("u:healing") end
    local rested = healing.tick(player)
    if errorlog and type(errorlog.spike_end) == "function" then errorlog.spike_end() end
    if rested then
        return
    end
    -- Self-buff upkeep. Sits with the class buffs because it answers the
    -- same question, and after healing.tick so a rest is never interrupted
    -- to refresh something.
    probe("u:buffs")
    if buffs and type(buffs.tick) == "function" and buffs.tick(player) then
        return
    end
    probe("u:buffs_ooc")
    if rotation.buffs_ooc(player) then
        return
    end
    probe("u:busy")
    if player_is_busy(player) then
        state.set_note("Wait", "Casting")
        return
    end

    -- Ahead of the vendor trip on purpose: both want the gossip frame, and
    -- selecting the trainer option replaces whatever is open. Training is the
    -- rarer opportunity, and vendor.tick re-opens the merchant by itself.
    probe("u:trainer")
    if trainer and type(trainer.tick) == "function" and trainer.tick(player) then
        return
    end
    probe("u:vendor")
    if vendor and vendor.tick(player) then
        return
    end

    -- After vendor on purpose: equipping and selling are the same underlying
    -- call (use_container_item), so this must be unreachable while a merchant
    -- window is open or an upgrade gets sold instead of worn.
    probe("u:equip")
    if equip and type(equip.tick) == "function" and equip.tick(player) then
        return
    end

    if path_runner then
        path_runner.stop()
    end

    local mode = gui.mode()
    if mode == modes.QUEST then
        local quest = loader and loader.ensure_quest() or nil
        if not quest then
            state.set_note("Quest", "Quest pack failed to load")
            return
        end
        if quest.is_ready(player) then
            probe("u:quest.tick")
            quest.tick(player)
            probe("u:quest.tick done")
        else
            state.set_note("Quest", "RestedXP Guides is not loaded")
        end
        return
    end

    if mode == modes.GRIND then
        local grind = loader and loader.ensure_grind() or nil
        if not grind then
            state.set_note("Grind", "Grind pack failed to load")
            return
        end
        probe("u:grind.tick")
        grind.tick(player)
        probe("u:grind.tick done")
        return
    end
end

local function on_render()
    if movement then
        pcall(movement.on_render)
    end
    -- pet_handler queues delayed state changes and moves and only runs them
    -- when it is pumped. A delay that silently never fires is a bad thing to
    -- leave lying around, so this runs whether or not anything uses one yet.
    -- No-op on a build without the handler.
    if pets and type(pets.on_render) == "function" then
        pcall(pets.on_render)
    end
    -- Debug lines are buffered and written on a debounce, because
    -- write_data_file overwrites rather than appends. Without this they are
    -- collected and never reach scripts_data.
    if debuglog and type(debuglog.tick) == "function" then
        pcall(debuglog.tick)
    end
    if is_stale() then
        return
    end
    if gui and gui.is_on("draw_path") and path_runner and type(path_runner.draw) == "function" then
        pcall(function()
            path_runner.draw()
        end)
    end
end

-- What the bot was doing, attached to every error in the log.
if errorlog then
    errorlog.set_context(function()
        local ctx = {}
        ctx.mode = gui and gui.mode() or "-"
        ctx.started = gui and gui.is_started() or false
        ctx.status = state and (tostring(state.note_head or "") .. " " .. tostring(state.note or "")) or "-"
        local me = safe(function() return izi.me() end)
        if me then
            local p = safe(function() return me:get_position() end)
            if p then
                ctx.position = string.format("%.1f, %.1f, %.1f", p.x or 0, p.y or 0, p.z or 0)
            end
            ctx.level = safe(function() return me:get_level() end)
            ctx.in_combat = safe(function() return me:is_in_combat() end)
        end
        ctx.map_id = safe(function() return core.get_map_id() end)
        ctx.map = safe(function() return core.get_map_name() end)
        if state and state.target then
            ctx.target = state.target.kind
        end
        local ok_g, guide = pcall(require, "quest/guide")
        if ok_g and type(guide) == "table" and type(guide.describe) == "function" then
            ctx.guide = safe(guide.describe)
        end
        return ctx
    end)
end

-- Sentinel navmesh requests since the last MEM line: the one allocation
-- source outside this plugin's own code that it can drive.
if errorlog then
    errorlog.set_mem_extra(function()
        local ok, R = pcall(require, "movement/rt")
        if not ok or type(R) ~= "table" then
            return nil
        end
        local text = string.format("sentinel requests %d issued, %d rate-limited",
            R.sn_issued or 0, R.sn_refused or 0)
        R.sn_issued, R.sn_refused = 0, 0
        return text
    end)
end

-- RestedXP may only be read inside this callback (quest/guide.lua,
-- allow_reads): never from a render hook.
local quest_guide = nil
do
    local ok, mod = pcall(require, "quest/guide")
    if ok and type(mod) == "table" and type(mod.allow_reads) == "function" then
        quest_guide = mod
    end
end

-- What each BEAT line reports beside the stages: status, health, combat,
-- and the kill target with its distance.
if errorlog then
    errorlog.set_beat_extra(function()
        local me = safe(function() return izi.me() end)
        local hp = me and safe(function() return me:get_health_percentage() end)
        -- Mana too (2.67.0): a rest that never starts is invisible without it.
        local mp = nil
        local mmax = me and safe(function() return me:mana_max() end)
        if type(mmax) == "number" and mmax > 0 then
            mp = safe(function() return me:mana_pct() end)
            if type(mp) ~= "number" then
                local cur = safe(function() return me:mana_current() end)
                mp = type(cur) == "number" and cur / mmax * 100 or nil
            elseif mp <= 1.5 then
                mp = mp * 100
            end
        end
        local cbt = me and safe(function() return me:is_in_combat() end)
        local tgt = "-"
        local u = state and state.target and state.target.unit
        if u and safe(function() return u:is_valid() end) ~= true then
            u = nil
        end
        if u then
            local name = safe(function() return u:get_name() end)
            local d = me and safe(function() return me:distance_to(u) end)
            tgt = string.format("%s %.1fy", tostring(name), tonumber(d) or -1)
        end
        return string.format("%s | hp %s%s%s | tgt %s",
            tostring(state and state.note or ""),
            hp and string.format("%.0f", hp) or "?",
            mp and string.format(" mp %.0f", mp) or "",
            cbt and " combat" or "", tgt)
    end)
end

core.register_on_update_callback(function()
    if quest_guide then
        quest_guide.allow_reads(true)
    end
    guarded("on_update", on_update)
    if quest_guide then
        quest_guide.allow_reads(false)
    end
    if errorlog then
        errorlog.tick_end()
    end
    probe("-")
end)
core.register_on_render_callback(function()
    probe("on_render")
    guarded("on_render", on_render)
    probe("-")
end)

core.log(string.format("[Master Farmer - Grindbot] v%s loaded by %s", identity.version, identity.authors))
