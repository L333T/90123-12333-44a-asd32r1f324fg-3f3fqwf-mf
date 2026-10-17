-- ============================================================================
-- Master Farmer - Grindbot
-- Gathering mode: patrol a route, gather herb / ore nodes, fight back
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 3.9.1
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- Port of EP_Herb_Mine (MainThread + Gather_Process), PORT_PLAYBOOK.md.
-- main.lua already runs death, loot, conjure, rest, buffs, trainer, vendor
-- and equip before this tick; what is left here, in the playbook's order:
--
--   1. teleport alarm (off by default): moved farther than the alarm yards in
--      one tick while alive -> stand still 90 s
--   2. fight back (3.8.1): a mob in combat that targets the player within the
--      fight-back yards is fought at once with the rotation - on the route
--      (Fight Attackers on, any health, any level) and always at a node - or a
--      fight already latched. The fight is the Grind tab's: targeting +
--      rotation.tick (Spells tab), never a class module of its own.
--   3. route (gather/route.select, re-checked every minute as ranks rise)
--   4. profession trainer trips (gather/trainer), then hunter ammo and
--      route food / drink trips (gather/supply, 2.238.0)
--   5. tracking aura (Find Herbs / Find Minerals) when missing
--   6. gather: step 1 patrol + scan, step 2 walk to the node and use it
--
-- Travel is Ameisen only (movement.follow_route / nav_to / nav_stop / halt).
-- The patrol walks the route as long chunks like the grind patrol; a node is
-- passed at NODE_PASS yards (the script's 1.7 yd single-point rule is what a
-- chunked route follower replaces).
-- ============================================================================


local gui = require("gui")
local state = require("state")
local targeting = require("targeting")
local movement = require("movement")
local rotation = require("rotation")
local healing = require("healing")
local spellbook = require("spellbook")
local route = require("gather/route")
local scan = require("gather/scan")
local mount = require("gather/mount")
local trainer = require("gather/trainer")
local supply = require("gather/supply")
local esp = require("gather/esp")          -- 3.9.1: nodes of a chosen path (the ESP node database)

local gather = {}

local NOTE = "Gather"
-- 3.0.0: one full lap per AmeisenNav follow_path (it cannot take a new list
-- without stopping); the next lap goes out when this one ends.
local CHUNK_MAX = 400
local NODE_PASS = 5.0
local FAR_JOIN = 120          -- farther than this from every waypoint: nav_to the nearest first
local USE_RANGE = 5           -- at or under this the node is used
local GONE_RANGE = 30         -- node gone within this: looted
local REJECT_RANGE = 1000     -- node farther than this: blacklisted
local RESCAN_RANGE = 10       -- one-time rescan around the stored point
local USE_GAP = 1.0
local LOOT_GAP = 0.3
local TRACK_GAP = 30
local ROUTE_CHECK = 60
local MOUNT_SUPPRESS = 10

-- Settings ids (Gathering tab, gui.lua).
local ID = {
    herb = "mfg_gather_herb",
    mine = "mfg_gather_mine",
    fight = "mfg_gather_fight",
    mount = "mfg_gather_mount",
    train = "mfg_gather_train",
    teleport = "mfg_gather_teleport",
    scan = "mfg_gather_scan",
    scan_gap = "mfg_gather_scan_gap",
    max = "mfg_gather_max",
    fight_yards = "mfg_gather_fight_yards",
    teleport_yards = "mfg_gather_teleport_yards",
    buy_food = "mfg_gather_buy_food",
    food_low = "mfg_gather_food_low",
    food_stock = "mfg_gather_food_stock",
    buy_ammo = "mfg_gather_buy_ammo",
    ammo_low = "mfg_gather_ammo_low",
    ammo_stop = "mfg_gather_ammo_stop",
    path = "mfg_gather_path",               -- 3.9.1: 1 = Auto, else a herbing / mining path
}

local S = nil

local function fresh()
    return {
        route = nil, reason = "not started", profile = nil,
        route_t = -1e9, prepare_t = -1e9,
        wp = 1,
        chunk = nil, chunk_idx = nil, chunk_k = 1,
        step = 1,
        node = nil, node_guid = nil, node_pos = nil, node_name = nil, node_since = 0,
        rescanned = false, use_t = -1e9, loot_t = -1e9, uses = 0,
        scan_t = -1e9,
        track_t = -1e9,
        last_pos = nil, pause_until = 0,
        fighting = false, fight_until = 0,
        gathered = 0,
    }
end
S = fresh()

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function now()
    local ok, t = pcall(core.time)                 -- 3.8.0: core API (was izi.now)
    return (ok and type(t) == "number") and t or 0
end

--- Distance between two game objects from get_position (3.8.1: Core API; distance_to is an izi extension).
local function unit_dist(a, b)
    local ok, pa, pb = pcall(function() return a:get_position(), b:get_position() end)
    if not ok or type(pa) ~= "table" or type(pb) ~= "table" then return nil end
    local dx, dy, dz = pa.x - pb.x, pa.y - pb.y, (pa.z or 0) - (pb.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function on(id) return gui.is_on(id) == true end

local function num(id, fallback)
    local v = gui.slider(id, fallback)
    if type(v) ~= "number" then return fallback end
    return v
end

local function flat(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function dist3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function here(player)
    local p = state.cached_pos or safe(function() return player:get_position() end)
    if p and type(p.x) == "number" then return p end
    return nil
end

local function wp_xyz(r, i)
    local w = r and r.waypoints and r.waypoints[i]
    if type(w) ~= "table" then return nil end
    local x, y, z = w.x or w[1], w.y or w[2], w.z or w[3]
    -- 3.9.1: a path without heights is walked at the player's height
    if r.no_z then
        local here = state.cached_pos
        z = (here and type(here.z) == "number") and here.z or 0
    end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { x = x, y = y, z = z }
end

local function needs()
    return on(ID.herb), on(ID.mine)
end

-- ----------------------------------------------------------------------------
-- Route
-- ----------------------------------------------------------------------------

local function merchant_of(r)
    local c = r and r.merchant_coord
    if type(c) ~= "table" or type(r.merchant) ~= "string" or r.merchant == "" then return nil end
    local x, y, z = c.x or c[2], c.y or c[3], c.z or c[4]
    if type(x) ~= "number" then return nil end
    return { name = r.merchant, x = x, y = y, z = z, map = c.mapid or c[1] }
end

local function nearest_wp(r, p)
    local best, best_d = 1, nil
    for i = 1, #(r.waypoints or {}) do
        local w = wp_xyz(r, i)
        if w then
            local d = flat(p, w)
            if not best_d or d < best_d then best, best_d = i, d end
        end
    end
    return best, best_d
end

local function log_map(r)
    local map = safe(function() return core.game_ui.get_current_map_id() end)
    core.log(string.format("[Master Farmer - Grindbot] Gather route %s (%s, %s), route mapid %s, UI map id %s",
        tostring(r.id), tostring(r.skill), tostring(r.faction), tostring(r.mapid), tostring(map)))
end

local function use_route(r, player)
    if S.route == r then return end
    S.route = r
    S.profile = { name = "Gather: " .. tostring(r.id), merchant = merchant_of(r), gather_route = r }
    S.chunk = nil
    local p = here(player)
    S.wp = p and (nearest_wp(r, p)) or 1
    log_map(r)
end

---3.9.1: the Gathering Path dropdown's path as a route, or nil (Auto).
local function chosen_path()
    return route.from_path(num(ID.path, 1))
end

---Selects the route for this character. False plus a reason when none fits.
function gather.prepare(player)
    player = player or safe(function() return core.object_manager.get_local_player() end)   -- 3.8.0: core API
    if not player then return false, "no player" end
    local need_herb, need_mine = needs()
    if not need_herb and not need_mine then
        S.reason = "Herbalism and Mining are both off"
        return false, S.reason
    end
    local pr = chosen_path()
    if pr then
        S.prepare_t, S.route_t = now(), now()
        S.reason = "path " .. tostring(pr.id)
        use_route(pr, player)
        return true, S.reason
    end
    local r, why = route.select(player, need_mine, need_herb)
    S.prepare_t, S.route_t = now(), now()
    S.reason = why
    if not r then return false, why end
    use_route(r, player)
    scan.refresh(need_herb, need_mine)
    return true, why
end

function gather.reset()
    pcall(function() movement.nav_stop() end)
    mount.reset()
    trainer.reset()
    supply.reset()
    S = fresh()
end

---The route being gathered, shaped for vendor.lua (merchant = {name,x,y,z}).
function gather.current_profile()
    return S.profile
end

---Read-only view for the Gathering tab.
function gather.status()
    return {
        route = S.route and S.route.id or nil,
        reason = S.reason,
        step = S.step,
        wp = S.wp,
        wp_count = S.route and #(S.route.waypoints or {}) or 0,
        node = S.node_name,
        gathered = S.gathered,
        paused = now() < S.pause_until and math.floor(S.pause_until - now()) or 0,
        training = trainer.busy(),
        supplying = supply.busy(),
    }
end

-- ----------------------------------------------------------------------------
-- Fight back (the grind fight, trimmed)
-- ----------------------------------------------------------------------------

local function end_fight()
    movement.nav_stop()
    movement.combat_release()
    state.reset_target()
    S.fighting = false
end

---Latch a target: a mob attacking the player (in combat, targeting the
---player - targeting.combat_scan) within the fight-back yards. 3.8.1: no
---health threshold and no level filter any more - whatever attacks the player
---gets the rotation. `near_node` = step 2 at the node: fought even with Fight
---Attackers off.
local function want_fight(player, near_node)
    if S.fighting then return true end
    if not near_node and not on(ID.fight) then return false end
    if safe(function() return player:is_in_combat() end) ~= true then return false end
    local pack = targeting.combat_scan(player, num(ID.fight_yards, 40))
    local unit = targeting.nearest(player, pack)
    if not unit then return false end
    targeting.set_current(unit, "kill")
    S.fighting = true
    S.fight_until = now() + 120
    state.set_note(NOTE, "Fight back")
    return true
end

local function fight(player)
    local cur_guid = (state.target.kind == "kill") and state.target.guid or nil
    local attacker = targeting.attacker_to_switch(player, cur_guid, num(ID.fight_yards, 40))
    if attacker then targeting.set_current(attacker, "kill") end

    local unit = state.target.unit
    if not unit or safe(function() return unit:is_valid() end) ~= true then
        if state.target.kind == "kill" and state.target.guid then
            state.mark_killed(state.target.guid)
            local ok_l, lt = pcall(require, "loot")
            if ok_l and type(lt) == "table" and type(lt.note_kill_guid) == "function" then
                lt.note_kill_guid(state.target.guid,
                    state.target.x and { x = state.target.x, y = state.target.y, z = state.target.z } or nil)
            end
        end
        return end_fight()
    end
    if safe(function() return unit:is_dead() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        local ok_l, lt = pcall(require, "loot")
        if ok_l and type(lt) == "table" and type(lt.note_kill) == "function" then lt.note_kill(unit) end
        return end_fight()
    end
    local dist = unit_dist(player, unit) or 99
    local in_combat = safe(function() return player:is_in_combat() end) == true
    if now() > S.fight_until or (dist > num(ID.fight_yards, 40) and not in_combat) then
        state.mark_killed(state.target.guid)
        return end_fight()
    end
    if safe(function() return player:is_mounted() end) == true then
        pcall(function() core.input.dismount() end)
    end
    targeting.ensure_target(player, unit)
    local yards = type(rotation.combat_range) == "function" and rotation.combat_range(player) or 30
    if type(yards) ~= "number" or yards < 1 then yards = 30 end
    if type(targeting.approach_stuck) == "function" and targeting.approach_stuck(player, unit, yards) then
        state.set_note(NOTE, "Skip unreachable")
        return end_fight()
    end
    local engaged = movement.combat_engage(player, unit, yards)
    movement.face(unit)
    -- 3.0.3: closing - into melee / casting range first, then attack
    if not engaged then
        state.set_note(NOTE, "Closing")
        return
    end
    targeting.start_auto_attack(player, unit)
    local pack = targeting.combat_scan(player, yards)
    state.set_note(NOTE, "Fighting")
    rotation.tick(player, unit, { enemies = pack, no_move = true })
end

-- ----------------------------------------------------------------------------
-- Travel helpers
-- ----------------------------------------------------------------------------

---Mount for a long leg. True while mounting holds the tick.
local function mount_up(player, far)
    if not far then return false end
    if mount.tick(player, on(ID.mount)) then
        movement.nav_stop()
        state.set_note(NOTE, "Mounting")
        return true
    end
    return false
end

local function build_chunk(r)
    local n = #(r.waypoints or {})
    local list, idx = {}, {}
    local i = (S.wp >= 1 and S.wp <= n) and S.wp or 1
    for _ = 1, math.min(CHUNK_MAX, n + 1) do
        local w = wp_xyz(r, i)
        if w and not movement.is_blocked(w) then
            list[#list + 1] = w
            idx[#idx + 1] = i
        end
        i = (i % n) + 1
    end
    return list, idx
end

-- 3.9.1: a path without heights (EMKO) is never follow_route'd at z = 0:
-- each move is one nav_to HOP yd ahead along it, from the player's height
-- (MasterArthasNav's exact server path finds the ground).
local HOP, HOP_ARRIVE = 30, 4

local function hop_from(r, n, i)
    local a = wp_xyz(r, i)
    if not a then return (i % n) + 1 end
    local k = 1
    while k < n - 1 do
        local j = ((i - 1 + k) % n) + 1
        local b = wp_xyz(r, j)
        if b and flat(a, b) >= HOP then return j end
        k = k + 1
    end
    return (i % n) + 1
end

local function hop_patrol(player, p, r, n)
    local w = wp_xyz(r, S.wp)
    if not w then S.wp = 1 return end
    if flat(p, w) <= HOP_ARRIVE then
        S.wp = hop_from(r, n, S.wp)
        w = wp_xyz(r, S.wp)
        S.hop_i = nil
    end
    state.set_note(NOTE, string.format("%s  waypoint %d / %d", tostring(r.id), S.wp, n))
    if mount_up(player, flat(p, w) > mount.TRAVEL_YARDS) then
        S.hop_i = nil
        return
    end
    if movement.is_moving() and S.hop_i == S.wp then return end
    S.hop_i = S.wp
    movement.nav_to(w)
end

---Step 1 travel: the route as long chunks (closed loop, wraps to waypoint 1).
local function patrol(player, p)
    local r = S.route
    local n = #(r.waypoints or {})
    if n < 2 then
        state.set_note(NOTE, "Route has no waypoints")
        return
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        state.set_note(NOTE, "Nav settle")
        return
    end
    -- Far from the route (start, after a vendor or trainer trip): go to the
    -- nearest waypoint first.
    local near_i, near_d = nearest_wp(r, p)
    if near_d and near_d > FAR_JOIN then
        S.chunk = nil
        S.wp = near_i
        local dest = wp_xyz(r, near_i)
        if mount_up(player, true) then return end
        state.set_note(NOTE, string.format("To route %s  %.0f yd", tostring(r.id), near_d))
        if not (movement.is_moving() and S.join_i == near_i) then
            S.join_i = near_i
            movement.nav_to(dest)
        end
        return
    end
    S.join_i = nil
    if r.no_z then return hop_patrol(player, p, r, n) end
    if S.chunk then
        local best_k, best_d = nil, nil
        for k = S.chunk_k, math.min(#S.chunk, S.chunk_k + 8) do
            local d = flat(p, S.chunk[k])
            if not best_d or d < best_d then best_k, best_d = k, d end
        end
        if best_k and best_d <= NODE_PASS then
            S.chunk_k = best_k + 1
            local nxt = S.chunk_idx[math.min(S.chunk_k, #S.chunk_idx)]
            if nxt then S.wp = nxt end
        end
    end
    local note = string.format("%s  waypoint %d / %d", tostring(r.id), S.wp, n)
    local remaining = S.chunk and (#S.chunk - S.chunk_k + 1) or 0
    local moving = movement.is_moving()
    if S.chunk and moving then
        local nxt = S.chunk[math.min(S.chunk_k, #S.chunk)]
        if nxt and mount_up(player, flat(p, nxt) > mount.TRAVEL_YARDS or remaining > 2) then
            S.chunk = nil
            return
        end
        state.set_note(NOTE, note)
        return
    end
    if mount_up(player, true) then
        S.chunk = nil
        return
    end
    local list, idx = build_chunk(r)
    if #list < 2 then
        state.set_note(NOTE, "Route blocked")
        return
    end
    if movement.follow_route(list, true) then
        S.chunk, S.chunk_idx, S.chunk_k = list, idx, 1
    end
    state.set_note(NOTE, note)
end

-- ----------------------------------------------------------------------------
-- Nodes
-- ----------------------------------------------------------------------------

local function node_alive(o)
    if not o or safe(function() return o:is_valid() end) ~= true then return false end
    return safe(function() return o:can_be_used() end) ~= false
end

local function back_to_patrol()
    S.step = 1
    S.node, S.node_guid, S.node_pos, S.node_name = nil, nil, nil, nil
    S.rescanned, S.uses = false, 0
    S.chunk = nil
end

local function take_node(o, pos)
    S.node = o
    S.node_guid = scan.guid_of(o)
    S.node_pos = pos or safe(function() return o:get_position() end)
    S.node_name = safe(function() return o:get_name() end) or "node"
    S.node_since = now()
    S.rescanned, S.uses = false, 0
    S.step = 2
end

local function loot_window()
    local n = tonumber(safe(function() return core.game_ui.get_loot_item_count() end)) or 0
    if n <= 0 then return false end
    if (now() - S.loot_t) < LOOT_GAP then return true end
    S.loot_t = now()
    for i = n - 1, 0, -1 do
        pcall(function() core.input.loot_item(i) end)
    end
    return true
end

local function gather_node(player, p)
    local t = now()
    local np = S.node_pos
    if not np then return back_to_patrol() end
    local d = dist3(p, np)
    if d > REJECT_RANGE then
        scan.blacklist(S.node_guid)
        return back_to_patrol()
    end
    if (t - S.node_since) > num(ID.max, 200) then
        core.log("[Master Farmer - Grindbot] Gather: gave up on " .. tostring(S.node_name) .. " (timer)")
        scan.blacklist(S.node_guid)
        return back_to_patrol()
    end
    if d < GONE_RANGE then
        mount.suppress(MOUNT_SUPPRESS)
        if not node_alive(S.node) then
            if loot_window() then
                state.set_note(NOTE, "Looting " .. tostring(S.node_name))
                return
            end
            scan.mark_looted(S.node_guid)
            if S.uses > 0 then S.gathered = S.gathered + 1 end
            pcall(function() core.input.close_loot() end)
            return back_to_patrol()
        end
    end
    if d > USE_RANGE then
        if mount_up(player, d > 60) then return end
        state.set_note(NOTE, string.format("To %s  %.0f yd", tostring(S.node_name), d))
        if not movement.is_moving() or (t - S.use_t) > 3 then
            S.use_t = t
            movement.nav_to(np)
        end
        return
    end
    -- At the node.
    if not S.rescanned then
        S.rescanned = true
        state.reset_target()
        -- 3.9.1: a path route's nodes come from the ESP database, not the EP rows
        if not (S.route and S.route.from_path) then
            local o = scan.closest(np, RESCAN_RANGE, false)
            if not o then return back_to_patrol() end
            if o ~= S.node then
                S.node = o
                S.node_guid = scan.guid_of(o)
            end
        end
    end
    if safe(function() return player:is_mounted() end) == true then
        pcall(function() core.input.dismount() end)
        return
    end
    movement.halt()
    if type(movement.pause_for_loot) == "function" then movement.pause_for_loot(2) end
    if loot_window() then
        state.set_note(NOTE, "Looting " .. tostring(S.node_name))
        return
    end
    if safe(function() return player:is_moving() end) == true then return end
    if (safe(function() return player:is_casting_spell() end) == true or safe(function() return player:is_channelling_spell() end) == true) then
        state.set_note(NOTE, "Gathering " .. tostring(S.node_name))
        return
    end
    if (t - S.use_t) < USE_GAP then return end
    S.use_t = t
    S.uses = S.uses + 1
    pcall(function() core.input.use_object(S.node) end)
    state.set_note(NOTE, "Gathering " .. tostring(S.node_name))
end

-- ----------------------------------------------------------------------------
-- Tracking aura
-- ----------------------------------------------------------------------------

local function keep_tracking(player)
    local t = now()
    if (t - S.track_t) < TRACK_GAP then return end
    S.track_t = t
    local need_herb, need_mine = needs()
    -- One tracking aura at a time: the route's own profession wins.
    local name
    local skill = S.route and S.route.skill
    if skill == "herbalism" and need_herb then name = "Find Herbs"
    elseif skill == "mining" and need_mine then name = "Find Minerals"
    elseif need_herb then name = "Find Herbs"
    elseif need_mine then name = "Find Minerals" end
    if not name then return end
    local fam = spellbook.family(name)
    if not fam or not fam.id then return end
    -- 3.8.1: the aura is read with get_buffs (declared; has_buff is not in the .api)
    local ids = { [fam.id] = true }
    for _, id in ipairs(fam.ranks or {}) do ids[id] = true end
    local buffs = safe(function() return player:get_buffs() end)
    if type(buffs) == "table" then
        for _, b in ipairs(buffs) do
            if type(b) == "table" and (ids[b.buff_id] or b.buff_name == name) then return end
        end
    end
    -- core API cast (spellcheck) by spell id - 3.8.0: no izi spell object either
    pcall(function() require("spellcheck").cast_safe(fam.id, player, "MF gather " .. name) end)
end

-- ----------------------------------------------------------------------------
-- Tick
-- ----------------------------------------------------------------------------

function gather.tick(player)
    if not player then return end
    local p = here(player)
    if not p then return end
    local t = now()

    -- 1. Teleport alarm.
    if on(ID.teleport) and S.last_pos then
        local moved = dist3(p, S.last_pos)
        if moved > num(ID.teleport_yards, 100) and safe(function() return player:is_dead() end) ~= true then
            core.log_warning(string.format("[Master Farmer - Grindbot] Gather: moved %.0f yd in one tick - pausing 90 s", moved))
            S.pause_until = t + 90
            S.last_pos = nil
            movement.nav_stop()
            return
        end
    end
    S.last_pos = { x = p.x, y = p.y, z = p.z }
    if t < S.pause_until then
        movement.nav_stop()
        state.set_note(NOTE, string.format("Teleport alarm  %d s", math.floor(S.pause_until - t)))
        return
    end

    -- 2. Fight back.
    local near_node = S.step == 2 and S.node_pos ~= nil and dist3(p, S.node_pos) <= USE_RANGE
    if want_fight(player, near_node) then
        fight(player)
        return
    end

    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        movement.nav_stop()
        return
    end

    local need_herb, need_mine = needs()

    -- 3. Profession trainer (out of combat, step 1 only). Before the route:
    -- a character without the profession has no route until it is learned.
    local path_route = chosen_path()
    if S.step == 1 and not path_route and trainer.tick(player, { herbalism = need_herb, mining = need_mine }, on(ID.train)) then
        S.chunk = nil
        return
    end

    -- 4. Route. 3.9.1: the Gathering Path dropdown changed -> switch at once.
    if S.step == 1 and S.route and S.route ~= path_route and (path_route or S.route.from_path) then
        movement.nav_stop()
        S.route = nil
        S.prepare_t = -1e9
    end
    if not S.route then
        if (t - S.prepare_t) >= 5 then gather.prepare(player) end
        if not S.route then
            movement.nav_stop()
            state.set_note(NOTE, tostring(S.reason or "No route"))
            return
        end
    elseif S.step == 1 and not S.route.from_path and (t - S.route_t) >= ROUTE_CHECK then
        S.route_t = t
        local r, why = route.select(player, need_mine, need_herb)
        S.reason = why
        if r and r ~= S.route then
            movement.nav_stop()
            use_route(r, player)
        end
    end
    scan.refresh(need_herb, need_mine)

    -- 4b. Hunter ammo / route food and drink (step 1 only, 2.238.0).
    if S.step == 1 and supply.tick(player, S.route, {
        ammo = on(ID.buy_ammo), ammo_low = num(ID.ammo_low, 100), ammo_stop = num(ID.ammo_stop, 500),
        food = on(ID.buy_food), food_low = num(ID.food_low, 5), food_stock = num(ID.food_stock, 20),
        mount_up = function(far) return mount_up(player, far) end,
    }) then
        S.chunk = nil
        return
    end

    -- 5. Tracking aura.
    if safe(function() return player:is_in_combat() end) ~= true then keep_tracking(player) end

    -- 6. Gather.
    if S.step == 2 then
        gather_node(player, p)
        return
    end
    local gap = num(ID.scan_gap, 1)
    if type(gap) ~= "number" then gap = 2 end
    if (t - S.scan_t) >= gap then
        S.scan_t = t
        local o, d, op
        if S.route.from_path then
            esp.update(player)
            local e
            e, d = esp.nearest(p, num(ID.scan, 200), { herb = need_herb, ore = need_mine })
            if e then o, op = e.obj, { x = e.x, y = e.y, z = e.z } end
        else
            o, d = scan.closest(p, num(ID.scan, 200))
        end
        if o then
            take_node(o, op)
            movement.nav_stop()
            state.set_note(NOTE, string.format("Node %s  %.0f yd", tostring(S.node_name), d or 0))
            return
        end
    end
    patrol(player, p)
end

return gather
