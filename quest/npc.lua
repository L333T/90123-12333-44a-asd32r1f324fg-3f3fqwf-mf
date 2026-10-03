-- ============================================================================
-- Master Farmer - Grindbot
-- Quest NPC interact / gossip / accept / turn-in
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 2.210.0
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- TWO FRAMES, NOT ONE
--   An NPC with quests shows either a GOSSIP frame (get_gossip_*_quests, keyed
--   by quest id) or a QUEST GREETING frame (get_available_title / get_active_
--   title, keyed by a 1-based INDEX). Only the gossip path existed before, so a
--   greeting-frame NPC fell through to a bare accept_quest() with nothing
--   selected and the bot stalled. Both paths are handled here.
--
-- COMPLETE vs GET_QUEST_REWARD ARE ALTERNATIVES
--   complete_quest() is for a quest with no reward choice. get_quest_reward(i)
--   SELECTS choice i AND completes the quest. They were being called one after
--   the other, which meant a quest offering a choice of rewards could never be
--   handed in: complete_quest() is refused while a choice is pending, and the
--   follow-up passed index 0, which is the "no choice" sentinel.
--
-- GREY QUESTS ARE SKIPPED, NOT DECLINED (1.6.0)
--   A gossip row carries is_trivial, which is the client's own answer to "is
--   this grey for me". When it is, the quest goes into the same skip bag the
--   GUI's manual skip uses and the engine moves on to the next one. It is not
--   declined: decline_quest dismisses the offer for this frame only, so the
--   bot would walk back and be offered the same quest on the next pass.
--
-- GOSSIP quest_id IS NOT A QUEST ID ON TBC (1.5.2)
--   On Classic Era and TBC Classic the legacy client sends no quest id with a
--   gossip list, so get_gossip_*_quests fills quest_id with the 1-BASED ROW
--   INDEX instead. It looks like an id and it round-trips back to the matching
--   selector, which is exactly what makes it dangerous: comparing it against a
--   real quest id never matches, and passing a real quest id to the selector
--   addresses a row that does not exist.
--
--   Both mistakes were here. The gossip path therefore never selected anything
--   on TBC - it only ever worked when the quest detail frame happened to be up
--   already. Quests are now matched on TITLE, and the opaque value from the
--   same frame is handed straight back to the selector, which is correct on
--   every version. Only the QUEST LOG carries a real quest id, so is_on_quest,
--   is_quest_flagged_completed and get_quest_log_title keep using ids.
--
-- INTERACTING IS NOT FREE (1.5.1)
--   go_and_interact re-issued interact_with_object every 1.2s for as long as
--   the bot stood at the NPC, and the dialog steps only ran on the tick that
--   fired. Re-interacting TEARS DOWN the open frame and opens a fresh one, so
--   the reward frame never lived long enough for get_quest_item_link to see a
--   choice - the hand-in fell through to complete_quest every time and a quest
--   with a reward choice could never finish. Walking to the NPC (npc.at_npc)
--   and driving the dialog (npc.accept / npc.turn_in) are now separate, and
--   the dialog is a state machine that interacts ONCE and then leaves the
--   frame alone while it reads it.
--
-- ESCORTS NEED A SECOND YES
--   accept_quest() is not enough for an auto-accept / escort quest; the client
--   raises a confirmation popup that confirm_accept_quest() answers.
--
-- AN INTERACT IS NOT A WINDOW (2.134.0)
--   interact_with_object returns true whether or not the NPC answered, and the
--   machine went straight on to read a frame. An interact from the wrong floor
--   or out of reach was read as "an empty frame", Continue and reward calls
--   went out against nothing, and the verify stage called the quest handed in
--   because it was simply not in a log the build cannot read. Now:
--     - "await" waits for a window to open (the events events.lua records, or
--       a gossip / greeting list that can be read) before anything is selected;
--       a UI error or silence is a failed attempt, not a frame;
--     - the NPC's own active row must say is_complete before it is selected;
--     - a hand-in is proven by QUEST_TURNED_IN, the completed flag, or the
--       quest leaving a log it was in when the attempt began.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")
local gamever = require("gamever")

local gossip = require("gossip")

local gui = require("gui")
local movement = require("movement")
local targeting = require("targeting")
local state = require("state")

local npc = {}

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

-- Walk an indexed NPC-frame list until the titles run out. There is no
-- get_num_* for these, and an index past the end returns an empty string.
local MAX_FRAME_QUESTS = 32

local function frame_titles(getter)
    local out = {}
    for i = 1, MAX_FRAME_QUESTS do
        local title = safe(function() return getter(i) end)
        if type(title) ~= "string" or title == "" then
            break
        end
        out[i] = title
    end
    return out
end

--- Index of `want` in `titles`, or nil.
---
--- Quest names in the data files are English and the client may not be, so an
--- exact match is tried first, then a case-insensitive one. A single-entry list
--- needs no match at all - there is only one thing it can be, which keeps the
--- common case working in every locale.
local function index_of_title(titles, want)
    local n = 0
    for _ in pairs(titles) do n = n + 1 end
    if n == 0 then
        return nil
    end
    if n == 1 then
        return 1
    end
    if type(want) ~= "string" or want == "" then
        return nil
    end
    for i, t in pairs(titles) do
        if t == want then return i end
    end
    local lower = want:lower()
    for i, t in pairs(titles) do
        if t:lower() == lower then return i end
    end
    return nil
end

local warned_frame = {}
local function warn_once(key, fmt, ...)
    if warned_frame[key] then return end
    warned_frame[key] = true
    core.log_warning(string.format("[Master Farmer - Grindbot] " .. fmt, ...))
end

local function gossip_open()
    return gossip.is_open()
end

local function gossip_close()
    if izi.gossip and type(izi.gossip.close) == "function" then
        pcall(function()
            izi.gossip.close()
        end)
    end
    pcall(function()
        core.quests.close_gossip()
    end)
end

function npc.name_of(player, npc_id)
    if not player or not npc_id then
        return nil
    end
    local unit = targeting.find_npc(player, npc_id, 80)
    if not unit then
        return nil
    end
    local name = safe(function() return unit:get_name() end)
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

--- Walk to `npc_id`. Returns true once the bot is standing at it - every tick,
--- and WITHOUT interacting. The dialog state machines below decide when to
--- interact, because re-interacting closes whatever frame they are reading.
-- The console line is kept - it is what you watch live - and the same text
-- also goes to scripts_data/mfg/debug.log, because a console line cannot be
-- scrolled back to or sent to anybody.
local function quest_debug(fmt, ...)
    -- Part of "Detailed session log" (2.188.0).
    if gui.is_on("session_detail") ~= true then
        return
    end
    local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    core.log("[Master Farmer - Grindbot] quest: " .. text)
    local ok, dbg = pcall(require, "debuglog")
    if ok and dbg and type(dbg.line) == "function" then
        dbg.line("quest", "%s", text)
    end
end

--- Find an NPC by id, falling back to its name.
---
--- get_npc_id is the reliable handle when the caller has a real creature
--- entry. A guide addon does not always: the id it reports may be a different
--- numbering, or missing entirely for a goal that only names its target. The
--- name is what the player sees and what the addon shows, so it is the honest
--- second key.
---
--- Returns the unit and how it was matched, so a caller can say which worked.
function npc.find(player, npc_id, name_a, name_b, range)
    range = range or 80
    if npc_id then
        local by_id = targeting.find_npc(player, npc_id, range)
        if by_id then
            return by_id, "id"
        end
    end
    if type(name_a) == "string" or type(name_b) == "string" then
        local by_name = targeting.find_named(player, name_a, name_b, range)
        if by_name then
            return by_name, "name"
        end
    end
    return nil, nil
end

--- Walk to an NPC and open its dialog.
---
--- at_npc only WALKS - it returns true once the NPC is in reach and leaves
--- the talking to npc.accept or npc.turn_in, which drive the quest frames.
--- A goal that is only "go and speak to this NPC" had nothing to call: the
--- bot arrived and stood there.
---
--- Interaction is rate limited by state.quest.interact_until, the same latch
--- the dialog state machine uses, because re-issuing interact_with_object
--- tears down the frame it just opened (1.5.1).
---
--- Returns true once the NPC is in reach, whether or not this tick was the
--- one that interacted.
function npc.talk(player, npc_id, dest, name_a, name_b)
    if not npc.at_npc(player, npc_id, dest, name_a, name_b) then
        return false
    end
    local now = izi.now()
    if now < (state.quest.interact_until or 0) then
        return true
    end
    local unit, how = npc.find(player, npc_id, name_a, name_b, 10)
    if not unit then
        quest_debug("talk: in reach but no unit matched id=%s name=%s/%s",
            tostring(npc_id), tostring(name_a), tostring(name_b))
        return true
    end
    quest_debug("talk: matched by %s, interacting", tostring(how))
    state.quest.interact_until = now + 1.2
    pcall(function()
        core.input.interact_with_object(unit)
    end)
    return true
end

function npc.at_npc(player, npc_id, dest, name_a, name_b)
    local unit = npc.find(player, npc_id, name_a, name_b, 80)
    if unit then
        local d = safe(function() return player:distance_to(unit) end) or 99
        if d > 4 then
            local p = safe(function() return unit:get_position() end) or dest
            movement.nav_to(p)
            return false
        end
        movement.nav_stop()
        return true
    end
    if dest then
        if not movement.arrived(dest, 4) then
            movement.nav_to(dest)
        end
    end
    return false
end

--- Open the NPC's dialog. Called once per state-machine attempt, never on a
--- timer: every call replaces the frame that is currently open.
---
--- `unit` is used when the caller already found the NPC - a RestedXP goal
--- names no NPC id, so the engine finds the giver itself and hands it over.
--- It must still be valid and in reach; otherwise the id is searched for.
local function interact_once(player, npc_id, unit)
    if unit and (safe(function() return unit:is_valid() end) ~= true
        or (safe(function() return player:distance_to(unit) end) or 99) > 10) then
        unit = nil
    end
    unit = unit or targeting.find_npc(player, npc_id, 10)
    if not unit then
        return false
    end
    state.quest.interact_until = izi.now() + 1.2
    pcall(function()
        core.input.interact_with_object(unit)
    end)
    return true
end

-- ----------------------------------------------------------------------------
-- WINDOW EVENTS (2.134.0)
-- ----------------------------------------------------------------------------
-- interact_with_object always returns true; whether the NPC answered is only
-- known from the window events events.lua records. There is no "quest frame
-- shown" query, so the detail / progress / completion panels are seen through
-- QUEST_DETAIL / QUEST_PROGRESS / QUEST_COMPLETE alone. events.live() stays
-- false until the core has delivered one of them this session; until then
-- the machine falls back to the timers it has always used.
local ok_ev, events = pcall(require, "events")
if not ok_ev or type(events) ~= "table" then
    events = nil
end

local ok_log, errorlog = pcall(require, "errorlog")
if not ok_log or type(errorlog) ~= "table" then
    errorlog = nil
end

local function trail(fmt, ...)
    quest_debug(fmt, ...)
    if errorlog and type(errorlog.trail) == "function" then
        errorlog.trail("npc", fmt, ...)
    end
end

local function ev_live()
    return events ~= nil and type(events.live) == "function" and events.live() == true
end

local function ev_since(name, t)
    return events ~= nil and type(events.since) == "function" and events.since(name, t) == true
end

local function ev_opened(t)
    if events ~= nil and type(events.opened_since) == "function" then
        return events.opened_since(t)
    end
    return nil
end

local function forever()
    return gamever.is_forever()
end

local function on_quest(quest_id)
    return safe(function() return core.quests.is_on_quest(quest_id) end)
end

local function flagged_done(quest_id)
    return safe(function() return core.quests.is_quest_flagged_completed(quest_id) end) == true
end

-- ----------------------------------------------------------------------------
-- DIALOG STATE MACHINE
-- ----------------------------------------------------------------------------
-- Each step gets its own tick. The client needs a frame or two to open a
-- window, and every step here reads a window the previous step opened.
--
--   interact -> await -> select -> wait -> finish -> reward -> verify   (turn in)
--   interact -> await -> select -> accept -> verify                     (accept)
--
-- "await" is the step that was missing: the machine used to go from interact
-- straight to reading a frame, so an interact the NPC never answered (out of
-- reach, wrong floor, busy) was read as an empty frame and walked on to
-- Continue and reward calls against nothing.
local STEP_GAP      = 0.5   -- seconds between steps
local FRAME_WAIT    = 2.0   -- timer fallback: how long to let a panel appear
local FRAME_TIMEOUT = 3.0   -- events live: no window by now means no answer
local VERIFY_WAIT   = 6.0   -- how long a completion may take to show
local INFO_WAIT     = 2.0   -- reward item info still loading
local MAX_TRIES     = 3

local MAX_NO_UNIT = 10     -- interact attempts with no NPC in reach before giving up

local WRONG_WINDOWS = { MERCHANT_SHOW = true, TRAINER_SHOW = true, TAXIMAP_OPENED = true }

-- QUEST GIVERS THAT ALSO TRAIN OR SELL (2.186.0). A class trainer who hands
-- out class quests can answer the interact with its TRAINER window (the
-- trainer module may just have picked "train me"), and a merchant who gives
-- quests with its goods. That used to end the dialog as "not_offered" and
-- rule the NPC out for good, so a class quest was never handed in to its
-- trainer. When the unit is a quest giver (npc flag 0x2), the window is
-- closed and the NPC asked again, up to MAX_TRIES, before giving up on it.
local function quest_giver_unit(unit)
    if not unit then return false end
    local f = safe(function() return unit:get_npc_flags() end)
    if type(f) ~= "number" then return true end      -- unreadable: give it the retries
    return math.floor(f / 2) % 2 == 1
end

local function close_service_windows()
    pcall(function() core.quests.close_trainer() end)
    pcall(function() core.input.close_merchant() end)
    pcall(function() core.taxi.close() end)
end

local dlg = {
    key = nil, stage = nil, t = -1e9, tries = 0, picked = nil, no_unit = 0, result = nil,
    t_interact = 0, frame = nil, continued = false, info_t = nil, was_on = nil,
    refused = false, seq = 0, label = "",
}

-- Quests this session has seen handed in, by id. Guards against selecting a
-- quest again while the log and RestedXP catch up.
local turned_in = {}

local function dlg_reset(key, label)
    dlg.key, dlg.stage, dlg.t, dlg.tries, dlg.picked = key, "interact", -1e9, 0, nil
    dlg.no_unit, dlg.result = 0, nil
    dlg.t_interact, dlg.frame, dlg.continued, dlg.info_t, dlg.was_on = 0, nil, false, nil, nil
    dlg.refused = false
    dlg.refusals = 0
    dlg.label = label or ""
end

-- Stages reached only by moving FORWARD through a dialog. Going back to
-- interact / await is a retry, which the engine's stall check must not
-- mistake for progress.
local FORWARD = { select = true, accept = true, wait = true, finish = true, reward = true, verify = true }

local function dlg_to(stage, now)
    if dlg.stage ~= stage then
        if FORWARD[stage] then
            dlg.seq = dlg.seq + 1
        end
        trail("%s %s: %s", dlg.key or "?", dlg.label, stage)
    end
    dlg.stage, dlg.t = stage, now
end

-- ----------------------------------------------------------------------------
-- QUEST LOG STATE (2.162.0)
-- ----------------------------------------------------------------------------
--- The quest log row of `quest_id`: "failed", "complete", "active", or nil
--- when it is not in the log (or the log cannot be read - WoW Forever), plus
--- its log index. get_quest_log_title: is_complete 1 complete, -1 failed.
local log_cache = { qid = nil, t = -1e9, st = nil, idx = nil }

function npc.quest_log_state(quest_id)
    if type(quest_id) ~= "number" then return nil end
    local t = izi.now()
    if log_cache.qid == quest_id and (t - log_cache.t) < 2.0 then
        return log_cache.st, log_cache.idx
    end
    local st, idx = npc.quest_log_scan(quest_id)
    log_cache.qid, log_cache.t, log_cache.st, log_cache.idx = quest_id, t, st, idx
    return st, idx
end

function npc.quest_log_scan(quest_id)
    pcall(function() core.quests.expand_quest_header(0) end)
    local n = safe(function() return core.quests.get_num_quest_log_entries() end) or 0
    for i = 1, n do
        local e = safe(function() return core.quests.get_quest_log_title(i) end)
        if type(e) == "table" and not e.is_header and e.quest_id == quest_id then
            if e.is_complete == -1 then return "failed", i end
            if e.is_complete == 1 then return "complete", i end
            return "active", i
        end
    end
    return nil
end

--- Abandon `quest_id` (a failed timed quest). True when the request was sent.
function npc.abandon(quest_id)
    local st, idx = npc.quest_log_scan(quest_id)
    log_cache.qid = nil
    if not idx then return false end
    local ok = pcall(function()
        core.quests.select_quest_log_entry(idx)
        core.quests.set_abandon_quest()
        core.quests.abandon_quest()
    end)
    trail("abandon quest %d (%s) at log index %d: %s", quest_id, tostring(st), idx, ok and "sent" or "failed")
    return ok
end

--- End the dialog with `result`, which is returned on every later call too
--- (2.63.0): "done" (landed), "skipped" (grey), "not_offered", "not_ready"
--- (the NPC lists the quest but will not take it yet), "gave_up".
local function dlg_finish(result)
    dlg.stage, dlg.result = "done", result
    dlg.seq = dlg.seq + 1
    trail("%s %s: finished - %s", dlg.key or "?", dlg.label, tostring(result))
    return result
end

--- One interact for the state machine. A miss (no NPC in reach yet) is NOT
--- a try (2.63.0): it used to use one up and move on to reading a frame that
--- was never opened, so three misses gave up on the right NPC.
local function dlg_interact(player, npc_id, unit, now)
    if interact_once(player, npc_id, unit) then
        dlg.tries = dlg.tries + 1
        dlg.no_unit = 0
        dlg.t_interact = now
        dlg.frame, dlg.continued, dlg.info_t, dlg.picked = nil, false, nil, nil
        dlg_to("await", now)
        return true
    end
    dlg.no_unit = dlg.no_unit + 1
    dlg.t = now
    return false
end

local function has_choices()
    local link = safe(function() return core.quests.get_quest_item_link("choice", 1) end)
    return type(link) == "string" and link ~= ""
end

local function greeting_lists()
    local act = frame_titles(function(i) return core.quests.get_active_title(i) end)
    local avail = frame_titles(function(i) return core.quests.get_available_title(i) end)
    return act, avail
end

--- Which window the last interact opened, "refused", "timeout", or nil while
--- it is still worth waiting.
local function await_frame(now)
    local since = dlg.t_interact
    local ev = ev_opened(since)
    if ev then
        return ev
    end
    if gossip_open() then
        return "GOSSIP_SHOW"
    end
    local act, avail = greeting_lists()
    if next(act) ~= nil or next(avail) ~= nil then
        return "QUEST_GREETING"
    end
    if has_choices() then
        return "QUEST_COMPLETE"
    end
    if ev_since("UI_ERROR_MESSAGE", since) then
        return "refused"
    end
    if (now - since) < FRAME_TIMEOUT then
        return nil
    end
    -- No event pump on this core: the old assumption, that a single-quest
    -- NPC opened a detail panel nothing here can see, is all there is.
    if not ev_live() then
        return "assumed"
    end
    return "timeout"
end

--- Back to interact after a failed attempt. The tries counter is what ends
--- it: three unanswered interacts is "gave_up", never an endless loop.
local function dlg_retry(now, why)
    trail("%s %s: %s - retrying (try %d of %d)", dlg.key or "?", dlg.label, why, dlg.tries, MAX_TRIES)
    dlg_to("interact", now)
end

-- ----------------------------------------------------------------------------
-- GOSSIP ROWS
-- ----------------------------------------------------------------------------
--- The NPC's gossip quests of `kind`, normalised to
--- { title, real_id, is_complete, is_trivial, pick }.
---
--- izi.gossip is preferred: its views say whether `id` is a real quest id
--- (has_real_id) and route :select() to the right selector on every build.
--- The raw rows are the fallback; their quest_id is a real id only on a
--- Blizzard client (Forever), and a row index on the private-server builds.
local function quest_rows(kind)
    local out = {}
    -- THE RAW ROWS FIRST (2.187.0), as the API's auto turn-in example does:
    -- core.quests.get_gossip_active_quests() / get_gossip_available_quests()
    -- and select_gossip_active_quest(quest.quest_id) /
    -- select_gossip_available_quest(quest.quest_id). quest_id is a real id
    -- on Blizzard clients and the row index on the private-server ones; it is
    -- handed straight back to the selector in this frame, never stored.
    local list = safe(function()
        if kind == "available" then
            return core.quests.get_gossip_available_quests()
        end
        return core.quests.get_gossip_active_quests()
    end)
    if type(list) == "table" and #list > 0 then
        local real = forever()
        for i = 1, #list do
            local r = list[i]
            local handle = r.quest_id
            out[#out + 1] = {
                title = r.title,
                real_id = real and r.quest_id or nil,
                is_complete = r.is_complete,
                is_trivial = r.is_trivial,
                pick = function()
                    if kind == "available" then
                        core.quests.select_gossip_available_quest(handle)
                    else
                        core.quests.select_gossip_active_quest(handle)
                    end
                end,
            }
        end
        return out
    end
    -- izi's views when the raw lists are empty.
    local g = izi.gossip
    local getter = g and (kind == "available" and g.available_quests or g.active_quests)
    if type(getter) == "function" then
        local views = safe(function() return getter() end)
        if type(views) == "table" then
            for i = 1, #views do
                local v = views[i]
                out[#out + 1] = {
                    title = v.title,
                    real_id = (v.has_real_id == true) and v.id or nil,
                    is_complete = v.is_complete,
                    is_trivial = v.is_trivial,
                    pick = function() v:select() end,
                }
            end
        end
    end
    return out
end

--- Find a quest in normalised rows: real id first (only where the build has
--- one), then title, then the only row there is.
local function find_row(rows, quest_id, quest_name)
    for i = 1, #rows do
        if rows[i].real_id ~= nil and rows[i].real_id == quest_id then
            return rows[i]
        end
    end
    if type(quest_name) == "string" and quest_name ~= "" then
        for i = 1, #rows do
            if rows[i].title == quest_name then
                return rows[i]
            end
        end
        local lower = quest_name:lower()
        for i = 1, #rows do
            if type(rows[i].title) == "string" and rows[i].title:lower() == lower then
                return rows[i]
            end
        end
    end
    if #rows == 1 then
        -- A single row with a real id that is not ours is someone else's quest.
        if rows[1].real_id ~= nil and rows[1].real_id ~= quest_id then
            return nil
        end
        return rows[1]
    end
    return nil
end

--- Raw-row lookup kept for npc.is_complete.
local function gossip_row(list, quest_id, quest_name)
    if type(quest_name) == "string" and quest_name ~= "" then
        for i = 1, #list do
            if list[i].title == quest_name then
                return list[i]
            end
        end
        local lower = quest_name:lower()
        for i = 1, #list do
            if type(list[i].title) == "string" and list[i].title:lower() == lower then
                return list[i]
            end
        end
    end
    if forever() then
        for i = 1, #list do
            if list[i].quest_id == quest_id then
                return list[i]
            end
        end
    end
    if #list == 1 then
        return list[1]
    end
    return nil
end

local function gossip_options_count()
    local opts = safe(function() return core.quests.get_gossip_options() end)
    return type(opts) == "table" and #opts or 0
end

--- Is this quest grey for us?
---
--- is_trivial is the client's own verdict but only appears on a gossip row, so
--- a greeting-frame NPC falls back to the quest level that frame reports. The
--- gap is deliberately conservative: TBC greys a quest around five levels below
--- the character, and skipping one that still pays is worse than running one
--- that does not.
local TRIVIAL_GAP = 5

local function is_trivial_quest(player, quest_id, quest_name)
    if gui.is_on("skip_trivial") ~= true then
        return false
    end

    if gossip_open() then
        local row = find_row(quest_rows("available"), quest_id, quest_name)
        return row ~= nil and row.is_trivial == true
    end

    -- Greeting frame: no is_trivial, but it does report the quest level.
    local titles = frame_titles(function(i) return core.quests.get_available_title(i) end)
    local idx = index_of_title(titles, quest_name)
    if not idx then
        return false
    end
    local qlevel = safe(function() return core.quests.get_available_level(idx) end)
    local plevel = safe(function() return player:get_level() end)
    if type(qlevel) ~= "number" or type(plevel) ~= "number" or qlevel <= 0 then
        return false
    end
    return (plevel - qlevel) >= TRIVIAL_GAP
end

--- Put the quest in the skip bag, so guide.goal passes over it and the
--- engine moves on to the step's next goal.
local function mark_skipped(quest_id, quest_name)
    if type(state.quest.skipped) ~= "table" then
        state.quest.skipped = {}
    end
    state.quest.skipped[quest_id] = true
    core.log(string.format(
        "[Master Farmer - Grindbot] Skipping grey quest %s.", tostring(quest_name or quest_id)))
end

--- Select `quest_id` at the NPC, whichever frame it is showing.
---
--- Returns one of:
---   "selected"     the row was selected; a quest panel should follow
---   "panel"        no list at all: a quest panel is (or is assumed) up
---   "not_listed"   the NPC lists quests and this one is not among them
---   "not_ready"    turn in only: listed, but the NPC marks it incomplete
-- 2.162.0: how long a gossip with options but no quest rows is given.
local ROWS_WAIT = 1.5

--- One trail line with everything the open gossip holds, for a "not listed".
local function dump_gossip(kind)
    local opts = safe(function() return core.quests.get_gossip_options() end) or {}
    local names = {}
    for i = 1, #opts do names[#names + 1] = tostring(opts[i].name) .. "/" .. tostring(opts[i].gossip_type) end
    local act = safe(function() return core.quests.get_gossip_active_quests() end) or {}
    local av = safe(function() return core.quests.get_gossip_available_quests() end) or {}
    local titles = {}
    for i = 1, #act do titles[#titles + 1] = "A:" .. tostring(act[i].title) end
    for i = 1, #av do titles[#titles + 1] = "N:" .. tostring(av[i].title) end
    local g = izi.gossip
    local iza = g and type(g.active_quests) == "function" and safe(function() return #g.active_quests() end) or -1
    trail("%s %s: gossip holds options [%s], quests [%s], izi active %s",
        dlg.key or "?", dlg.label, table.concat(names, ", "), table.concat(titles, ", "), tostring(iza))
end

local function select_quest(quest_id, quest_name, kind)
    if gossip_open() then
        local rows = quest_rows(kind)
        if #rows > 0 then
            local row = find_row(rows, quest_id, quest_name)
            if not row then
                trail("%s quest '%s' is not in this NPC's gossip list of %d",
                    kind, tostring(quest_name or quest_id), #rows)
                return "not_listed"
            end
            if kind == "active" and row.is_complete == false then
                return "not_ready"
            end
            pcall(row.pick)
            quest_debug("selected %s quest '%s' in the gossip frame", kind, tostring(row.title))
            return "selected"
        end
        if gossip_options_count() > 0 then
            -- Options but no quest rows yet (2.162.0): a class trainer's
            -- gossip (train, unlearn, the quest) can list its options a
            -- moment before its quests. The caller waits ROWS_WAIT first.
            return "no_rows"
        end
        return "panel"
    end

    local titles = frame_titles(function(i)
        if kind == "available" then
            return core.quests.get_available_title(i)
        end
        return core.quests.get_active_title(i)
    end)
    local idx = index_of_title(titles, quest_name)
    if idx then
        pcall(function()
            if kind == "available" then
                core.quests.select_available_quest(idx)
            else
                core.quests.select_active_quest(idx)
            end
        end)
        quest_debug("selected %s quest at greeting-frame index %d (%s)", kind, idx, tostring(titles[idx]))
        return "selected"
    end
    if next(titles) ~= nil then
        warn_once(kind .. ":" .. tostring(quest_id),
            "Quest %s is not among the quests this NPC lists by that name - "
            .. "the quest data name may not match the client's locale.",
            tostring(quest_name or quest_id))
        return "not_listed"
    end
    -- A greeting that lists only the OTHER kind (turning in at an NPC that
    -- shows only new quests) does not have this one.
    local act, avail = greeting_lists()
    if next(act) ~= nil or next(avail) ~= nil then
        return "not_listed"
    end
    return "panel"
end

-- ----------------------------------------------------------------------------
-- REWARD CHOICE
-- ----------------------------------------------------------------------------
local MAX_REWARD_CHOICES = 10

--- The reward choices currently on offer, as { index, link } pairs.
--- An index past the last choice returns "", which ends the list.
local function reward_choices()
    local out = {}
    for i = 1, MAX_REWARD_CHOICES do
        local link = safe(function() return core.quests.get_quest_item_link("choice", i) end)
        if type(link) ~= "string" or link == "" then
            break
        end
        out[#out + 1] = { index = i, link = link }
    end
    return out
end

--- Best choice index for this character.
---
--- Ranked by equip.rate: a usable upgrade beats a usable item, which beats
--- something not equippable at all, which beats an item this class cannot use.
--- Vendor price only breaks ties. Picking blind - which is what index 0 did -
--- routinely took a plate chest on a Mage.
---
--- An item the client has not cached yet comes back as an info table with no
--- name, which equip.rate would call "not equippable". That is waited out for
--- INFO_WAIT seconds (`waited`) before the choice is made on what is known.
---
--- Returns (index or nil, number of choices, ready).
local function best_choice(player, waited)
    local choices = reward_choices()
    if #choices == 0 then
        return nil, 0, true
    end

    local ok_equip, equip = pcall(require, "equip")
    local can_rate = ok_equip and type(equip) == "table" and type(equip.info_of) == "function"
    local best_idx, best_rating, best_name = nil, nil, nil
    local missing = false

    for i = 1, #choices do
        local c = choices[i]
        local info = can_rate and equip.info_of(c.link) or nil
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            local rating = equip.rate(player, info)
            if rating then
                quest_debug("  choice %d: %s - tier %d (%s) ilvl %d q%d %dc",
                    c.index, tostring(info.name), rating.tier, tostring(rating.reason),
                    rating.item_level, rating.quality, rating.sell_price)
                if equip.rating_beats(rating, best_rating) then
                    best_idx, best_rating, best_name = c.index, rating, info.name
                end
            end
        else
            missing = true
        end
    end

    if missing and can_rate and waited < INFO_WAIT then
        return nil, #choices, false
    end
    if not best_idx then
        best_idx, best_name = choices[1].index, choices[1].link
        warn_once("reward_blind:" .. tostring(dlg.key),
            "No item info for any reward of %s - taking choice 1.", tostring(dlg.label))
    elseif missing then
        trail("%s: some reward info never loaded - chose among the rest", tostring(dlg.label))
    end
    trail("%s: taking reward choice %d (%s)", tostring(dlg.label), best_idx, tostring(best_name))
    return best_idx, #choices, true
end

-- ----------------------------------------------------------------------------
-- ACCEPT
-- ----------------------------------------------------------------------------
--- Accept `quest_id`. Call every tick while standing at the NPC.
--- `unit` is optional: the NPC when the caller already has it.
function npc.accept(player, quest_id, quest_name, npc_id, unit)
    local key = "accept:" .. tostring(quest_id)
    if dlg.key ~= key then
        dlg_reset(key, tostring(quest_name or quest_id))
    end
    if dlg.stage == "done" then
        return dlg.result
    end
    local now = izi.now()
    if (now - dlg.t) < STEP_GAP then
        return
    end

    if dlg.stage == "interact" then
        -- Already in the log (accepted by hand, or the guide lagging): there
        -- is nothing to do at this NPC (2.63.0).
        if on_quest(quest_id) == true then
            return dlg_finish("done")
        end
        if flagged_done(quest_id) then
            return dlg_finish("done")
        end
        if dlg.tries >= MAX_TRIES or dlg.no_unit >= MAX_NO_UNIT then
            return dlg_finish("gave_up")
        end
        dlg_interact(player, npc_id, unit, now)
        return
    end

    if dlg.stage == "await" then
        local frame = await_frame(now)
        if frame == nil then
            return
        end
        if frame == "refused" then
            dlg.refused = true
            return dlg_retry(now, "the NPC refused the interaction")
        end
        if frame == "timeout" then
            return dlg_retry(now, "no window opened")
        end
        if WRONG_WINDOWS[frame] then
            if quest_giver_unit(unit) and dlg.tries < MAX_TRIES then
                close_service_windows()
                return dlg_retry(now, "the NPC opened " .. frame .. " - closing it and asking for its quests")
            end
            trail("accept %s: the NPC opened %s, not quests", dlg.label, frame)
            return dlg_finish("not_offered")
        end
        dlg.frame = frame
        dlg_to("select", now)
        return
    end

    if dlg.stage == "select" then
        -- A single-quest NPC skips the list and shows the detail panel.
        if dlg.frame == "QUEST_DETAIL" and not gossip_open() then
            dlg_to("accept", now)
            return
        end
        if is_trivial_quest(player, quest_id, quest_name) then
            mark_skipped(quest_id, quest_name)
            return dlg_finish("skipped")
        end
        local r = select_quest(quest_id, quest_name, "available")
        if r == "no_rows" then
            if (now - dlg.t) < ROWS_WAIT then return end
            dump_gossip("available")
            r = "not_listed"
        end
        if r == "not_listed" then
            return dlg_finish("not_offered")
        end
        dlg.t_interact = (r == "selected") and now or dlg.t_interact
        dlg_to("accept", now)
        return
    end

    if dlg.stage == "accept" then
        -- The detail panel has no "shown" query; with events live it must
        -- have announced itself before accept_quest is worth calling.
        if ev_live() and not ev_since("QUEST_DETAIL", dlg.t_interact) and dlg.frame ~= "QUEST_DETAIL" then
            if (now - dlg.t) >= FRAME_TIMEOUT then
                return dlg_retry(now, "no quest detail panel after selecting")
            end
            return
        end
        pcall(function() core.quests.accept_quest() end)
        -- Escort and other auto-accept quests raise a second confirmation
        -- popup; without this they sit on screen and never start.
        pcall(function() core.quests.confirm_accept_quest() end)
        dlg_to("verify", now)
        return
    end

    if dlg.stage == "verify" then
        local on = on_quest(quest_id)
        if on == true then
            return dlg_finish("done")
        end
        if on == nil and ev_since("QUEST_ACCEPTED", dlg.t_interact) then
            return dlg_finish("done")
        end
        if (now - dlg.t) >= VERIFY_WAIT then
            if ev_since("QUEST_ACCEPTED", dlg.t_interact) then
                warn_once("accept_other:" .. tostring(quest_id),
                    "Accepted a quest at this NPC, but %s is still not in the log - "
                    .. "it offered a different quest.", dlg.label)
                return dlg_finish("not_offered")
            end
            -- FULL BAGS (2.160.0). The NPC showed the quest and Accept was
            -- clicked, but it never landed. The client said the bags are
            -- full, or it happened twice: that is the bags (a quest that
            -- hands over an item), not a wrong NPC - vendor first.
            local ok_ev, ev = pcall(require, "events")
            local full = ok_ev and type(ev) == "table" and type(ev.inventory_full_since) == "function"
                and ev.inventory_full_since(dlg.t_interact)
            dlg.refusals = (dlg.refusals or 0) + 1
            if full or dlg.refusals >= 2 then
                return dlg_finish("bags_full")
            end
            return dlg_retry(now, "still not on the quest")
        end
    end
end

-- ----------------------------------------------------------------------------
-- TURN IN
-- ----------------------------------------------------------------------------
--- Proof a hand-in landed, or nil. Any one of: the client said so
--- (QUEST_TURNED_IN), the quest is flagged completed, or it was in the log
--- when this attempt began and is gone now. "Not in the log" alone is not
--- proof: it is also true of a quest that was never picked up.
local function turnin_landed(quest_id)
    if ev_since("QUEST_TURNED_IN", dlg.t_interact) then
        return "QUEST_TURNED_IN"
    end
    if flagged_done(quest_id) then
        return "flagged completed"
    end
    if dlg.was_on == true and on_quest(quest_id) == false then
        return "left the quest log"
    end
    -- The quest log itself (2.187.0): no longer listed, where the log can be
    -- read and the quest was in it when this attempt began.
    if dlg.was_on == true and type(npc.quest_log_state) == "function"
        and npc.quest_log_scan(quest_id) == nil
        and (safe(function() return core.quests.get_num_quest_log_entries() end) or 0) > 0 then
        return "gone from the quest log"
    end
    return nil
end

--- Hand in `quest_id`. Call every tick while standing at the NPC.
--- `unit` is optional: the NPC when the caller already has it.
function npc.turn_in(player, quest_id, quest_name, npc_id, unit)
    local key = "turnin:" .. tostring(quest_id)
    if dlg.key ~= key then
        dlg_reset(key, tostring(quest_name or quest_id))
    end
    if dlg.stage == "done" then
        return dlg.result
    end
    local now = izi.now()
    if (now - dlg.t) < STEP_GAP then
        return
    end

    if dlg.stage == "interact" then
        -- Handed in already (2.63.0), including earlier this session.
        if turned_in[quest_id] or (on_quest(quest_id) ~= true and flagged_done(quest_id)) then
            return dlg_finish("done")
        end
        if dlg.tries >= MAX_TRIES or dlg.no_unit >= MAX_NO_UNIT then
            warn_once("turnin_giveup:" .. tostring(quest_id),
                "Gave up handing in quest %s after %d attempts.",
                tostring(quest_name or quest_id), MAX_TRIES)
            return dlg_finish("gave_up")
        end
        dlg.was_on = on_quest(quest_id)
        dlg_interact(player, npc_id, unit, now)
        return
    end

    if dlg.stage == "await" then
        local frame = await_frame(now)
        if frame == nil then
            return
        end
        if frame == "refused" then
            dlg.refused = true
            return dlg_retry(now, "the NPC refused the interaction")
        end
        if frame == "timeout" then
            return dlg_retry(now, "no window opened")
        end
        if WRONG_WINDOWS[frame] then
            if quest_giver_unit(unit) and dlg.tries < MAX_TRIES then
                close_service_windows()
                return dlg_retry(now, "the NPC opened " .. frame .. " - closing it and asking for its quests")
            end
            trail("turn in %s: the NPC opened %s, not quests", dlg.label, frame)
            return dlg_finish("not_offered")
        end
        dlg.frame = frame
        dlg_to("select", now)
        return
    end

    if dlg.stage == "select" then
        -- A single-quest NPC can open the progress or completion panel
        -- directly; there is no list to pick from then.
        if ev_since("QUEST_COMPLETE", dlg.t_interact) or has_choices() then
            dlg_to("finish", now)
            return
        end
        if ev_since("QUEST_PROGRESS", dlg.t_interact) and not gossip_open() then
            dlg_to("wait", now)
            return
        end
        local r = select_quest(quest_id, quest_name, "active")
        if r == "no_rows" then
            if (now - dlg.t) < ROWS_WAIT then return end
            dump_gossip("active")
            r = "not_listed"
        end
        if r == "not_listed" then
            return dlg_finish("not_offered")
        end
        if r == "not_ready" then
            trail("turn in %s: the NPC lists it as not complete yet", dlg.label)
            return dlg_finish("not_ready")
        end
        if r == "panel" and ev_live() and dlg.frame == "QUEST_DETAIL" then
            -- The NPC went straight to OFFERING a quest: ours is not here.
            trail("turn in %s: the NPC offered a new quest instead", dlg.label)
            return dlg_finish("not_offered")
        end
        if r == "selected" then
            -- AUTO TURN-IN (2.187.0): select_gossip_active_quest, then
            -- complete_quest at once - the progress panel's Continue - as the
            -- API example does, instead of waiting for a QUEST_PROGRESS event
            -- that may come late or not at all. The completion panel (reward
            -- choice, get_quest_reward) and the verify step follow.
            pcall(function() core.quests.complete_quest() end)
            dlg.continued = true
            trail("turn in %s: selected and continued", dlg.label)
            dlg_to("finish", now)
            return
        end
        dlg_to("wait", now)
        return
    end

    -- Wait for the progress or the completion panel the selection opens.
    if dlg.stage == "wait" then
        if ev_since("QUEST_COMPLETE", dlg.t_interact) or has_choices() then
            dlg_to("finish", now)
            return
        end
        local progress = ev_since("QUEST_PROGRESS", dlg.t_interact)
        if progress or (not ev_live() and (now - dlg.t) >= FRAME_WAIT) then
            -- complete_quest is the PROGRESS panel's "Continue". The quest is
            -- not handed in until the completion panel is finished too
            -- (2.50.0) - that is the finish stage.
            pcall(function() core.quests.complete_quest() end)
            dlg.continued = true
            dlg_to("finish", now)
            return
        end
        if ev_live() and (now - dlg.t) >= FRAME_TIMEOUT then
            return dlg_retry(now, "no quest panel after selecting")
        end
        return
    end

    -- The completion panel: take the best reward choice, or finish with
    -- none (get_quest_reward(0) is "Complete Quest" with no choice).
    if dlg.stage == "finish" then
        if ev_since("QUEST_TURNED_IN", dlg.t_interact) then
            dlg_to("verify", now)
            return
        end
        local up = ev_since("QUEST_COMPLETE", dlg.t_interact) or has_choices()
        if not up then
            if ev_live() then
                if (now - dlg.t) >= FRAME_TIMEOUT then
                    if dlg.continued then
                        -- Continue did not lead to a completion panel: the
                        -- server still wants the objectives.
                        trail("turn in %s: Continue opened no completion panel", dlg.label)
                        return dlg_finish("not_ready")
                    end
                    return dlg_retry(now, "no completion panel")
                end
                return
            end
            if (now - dlg.t) < 0.8 then
                return
            end
        end
        dlg.info_t = dlg.info_t or now
        local idx, _, ready = best_choice(player, now - dlg.info_t)
        if not ready then
            return
        end
        if idx then
            dlg.picked = idx
            dlg_to("reward", now)
            return
        end
        pcall(function() core.quests.get_quest_reward(0) end)
        dlg_to("verify", now)
        return
    end

    if dlg.stage == "reward" then
        -- get_quest_reward SELECTS the choice and completes the quest.
        -- complete_quest is not called as well: they are alternatives.
        local idx = dlg.picked
        pcall(function() core.quests.get_quest_reward(idx) end)
        dlg_to("verify", now)
        return
    end

    if dlg.stage == "verify" then
        local how = turnin_landed(quest_id)
        if how then
            turned_in[quest_id] = now
            trail("turn in %s: confirmed (%s)", dlg.label, how)
            return dlg_finish("done")
        end
        if (now - dlg.t) >= VERIFY_WAIT then
            -- No proof either way. Without an event pump and without a log
            -- flag, "gone from the log" is the only signal the build has.
            if not ev_live() and on_quest(quest_id) == false then
                turned_in[quest_id] = now
                trail("turn in %s: confirmed (no longer on the quest)", dlg.label)
                return dlg_finish("done")
            end
            trail("turn in %s: NOT confirmed - still on the quest, trying again (try %d of %d)",
                dlg.label, dlg.tries, MAX_TRIES)
            return dlg_retry(now, "hand-in not confirmed")
        end
    end
end

--- Close the NPC's windows and forget the dialog.
function npc.close()
    dlg.key, dlg.stage, dlg.result = nil, nil, nil
    npc.close_frames()
end

--- Close the NPC's windows but keep the dialog's result, so a finished
--- dialog keeps answering with it instead of starting over.
function npc.close_frames()
    pcall(function()
        core.quests.close_quest()
    end)
    gossip_close()
end

--- A counter that moves whenever the dialog advances or finishes.
function npc.progress_seq()
    return dlg.seq
end

function npc.stage()
    return dlg.stage
end

--- True once, after the NPC refused an interact (out of range, facing, a
--- UI error): the caller should close in before the next attempt.
function npc.take_refused()
    local r = dlg.refused
    dlg.refused = false
    return r
end

--- Was `quest_id` confirmed handed in this session?
function npc.was_turned_in(quest_id)
    return quest_id ~= nil and turned_in[quest_id] ~= nil
end

--- WoW Forever (2.123.0): no quest-log index API. A quest is ready to hand in
--- when RestedXP reports objectives for it and every one is finished; nil
--- when RestedXP has nothing to say (the gossip list decides then).
local function rxp_complete(quest_id)
    local ok, guide = pcall(require, "quest/guide")
    if not ok or type(guide) ~= "table" or type(guide.objectives) ~= "function" then
        return nil
    end
    local list = guide.objectives(quest_id)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    for i = 1, #list do
        if not list[i].finished then return false end
    end
    return true
end

--- Is `quest_id` ready to hand in?
--- `quest_name` is only needed for the gossip fallback, where TBC exposes no
--- real quest id (see the header).
function npc.is_complete(quest_id, quest_name)
    if forever() then
        if safe(function() return core.quests.is_on_quest(quest_id) end) == false then
            return false
        end
        local done = rxp_complete(quest_id)
        if done ~= nil then
            return done
        end
        local gossip = safe(function() return core.quests.get_gossip_active_quests() end)
        if type(gossip) == "table" and #gossip > 0 then
            local row = gossip_row(gossip, quest_id, quest_name)
            return row ~= nil and row.is_complete == true
        end
        return false
    end
    pcall(function()
        core.quests.expand_quest_header(0)
    end)
    local n = safe(function() return core.quests.get_num_quest_log_entries() end) or 0
    for i = 1, n do
        local entry = safe(function() return core.quests.get_quest_log_title(i) end)
        if type(entry) == "table" and entry.quest_id == quest_id then
            -- Builds disagree on this field: the reference declares it as an
            -- integer (1 complete, -1 failed) and the documentation as a
            -- boolean. Accept either rather than pick a side.
            if entry.is_complete == true or entry.is_complete == 1 then
                return true
            end
            if entry.is_complete == -1 then
                return false  -- failed, not completable
            end
            local boards = safe(function() return core.quests.get_num_quest_leader_boards(i) end) or 0
            if boards > 0 then
                local all = true
                for b = 1, boards do
                    local obj = safe(function() return core.quests.get_quest_log_leader_board(b, i) end)
                    if not (type(obj) == "table" and obj.is_completed == true) then
                        all = false
                    end
                end
                return all
            end
            return false
        end
    end
    -- Not in the log we could read. The NPC's own active list knows whether it
    -- will take the quest back right now - matched on title, because the
    -- quest_id in a gossip row is a row index on TBC.
    local gossip = safe(function() return core.quests.get_gossip_active_quests() end)
    if type(gossip) == "table" and #gossip > 0 then
        local row = gossip_row(gossip, quest_id, quest_name)
        if row and row.is_complete == true then
            return true
        end
    end
    return false
end

return npc
