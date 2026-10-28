-- ============================================================================
-- Master Farmer - RestedXP Questing & Grinding
-- quest/diag.lua - step automation diagnostics (LOGGING ONLY)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Folder: Master_Farmer_Grindbot
-- ============================================================================
-- WHY (audit F7, 2026-10-28; ported from zygor_questing 2026-10-28)
--   F7 was raised against the Zygor product: a 20-minute session log carried
--   only two "quest: step" lines, and the log could not tell "progression is
--   driven by goal completion" apart from "the bot follows the live arrow and
--   the step changes under it". This product reads the same shape of guide -
--   one step, its goals, one arrow, re-read every update (quest/guide.lua
--   refresh) - so the same question applies here and the same numbers settle
--   it. Nothing is changed on a guess.
--
-- WHAT THIS DOES
--   Nothing, except write to the error log. It owns no state the engine reads,
--   it is never consulted by a decision, and every entry point is wrapped by
--   its callers in pcall. It records:
--
--     * STEP TRANSITIONS, with the goal ledger of the step being left - how
--       many of its goals RestedXP had marked complete, how many the bot was
--       holding itself, how many were open, and which ones. A step left with
--       open goals did NOT progress through goal completion; a step left with
--       everything done or held did.
--     * GOAL TRANSITIONS inside a step (index, action, what), so a step that
--       works through its goals in order is visible as such.
--     * ARROW TYPE ACCOUNTING - a tally by type, the types this product cannot
--       walk to included, so an odd type in a log is a counted fact instead of
--       an eyebrow-raise.
--     * CORPSE RUNS, so a session shows the bot's own corpse run (death.lua,
--       from core.game_ui.get_corpse_position) next to the guide reads around
--       it.
--     * A SUMMARY every SUMMARY_GAP seconds while the bot is running: step
--       reads, step changes, goal changes, how many step changes left open
--       goals behind, and the arrow tally. One line, and only when something
--       changed since the last one.
--
--   HELD GOALS (the port's one addition, 2026-10-28). This product finishes
--   goals itself - guide.mark_goal_done(step_num, index) - and RestedXP never
--   marks those complete (that is why guide.forget_local_done exists).
--   Counting them as "open" would have made every locally finished goal look
--   like a step that moved on its own, so quest/guide.lua passes the hold test
--   to D.step and they are counted apart.
--
--   Read a session's log with:
--     grep "diag" <scripts_log>/MASTER_FARMER_ERRORS/session_*.log
--
--   What answers audit F7: if "left open goals" is 0 over a long session, goal
--   completion IS driving progression and F7 is closed for this product. If it
--   is most of the step changes, the engine is following the arrow and the step
--   moves on its own - which is the thing worth fixing, and this says so in
--   numbers.
-- ============================================================================

local D = {}

-- One switch. Off = every entry point returns immediately and nothing is
-- logged; the module still loads so callers need no extra guard.
D.ON = true

local SUMMARY_GAP = 120      -- s between summary lines (only when something changed)
local GOAL_LIST_MAX = 6      -- open goals named in a transition line, at most
local TEXT_MAX = 40          -- a goal's text, trimmed, in a transition line

local arrows = {}            -- arrow type (or "none") -> count
local arrow_order = {}       -- first-seen order, so the summary reads the same way twice
local reads = 0              -- step reads that produced a step
local step_changes = 0
local goal_changes = 0
local left_open = 0          -- step changes that left unfinished goals behind
local corpse_runs = 0
local last_step = nil
local last_step_goals = nil  -- the goal ledger of the step we are on
local last_goal_key = nil
local next_summary = 0
local dirty = false          -- something happened since the last summary

local function trail(fmt, ...)
    local ok, log = pcall(require, "errorlog")
    if ok and type(log) == "table" and type(log.trail) == "function" then
        pcall(log.trail, "diag", fmt, ...)
    end
end

local function now()
    local ok, t = pcall(izi.now)
    if ok and type(t) == "number" then return t end
    local ok2, t2 = pcall(function() return core.time() end)
    if ok2 and type(t2) == "number" then return t2 end
    return 0
end

--- A goal in one phrase: "3 kill Kobold Vermin slain: 4/8". RestedXP goals
--- carry action / text / quest_id - there is no .target on them.
local function goal_label(g, i)
    local act = (type(g.action) == "string" and g.action ~= "") and g.action or "?"
    local what = (type(g.text) == "string" and g.text ~= "") and g.text or nil
    if what == nil and g.quest_id then what = "quest " .. tostring(g.quest_id) end
    what = what or "-"
    if #what > TEXT_MAX then what = string.sub(what, 1, TEXT_MAX) .. "..." end
    return string.format("%d %s %s", i, act, what)
end

--- The goals of a step as { done = n, held = n, open = n, open_names = {...} }.
--- `held` is a function(index) -> truthy when the bot finished that goal
--- itself (guide.mark_goal_done); optional, and it is never counted as open.
local function ledger(step, held)
    local out = { done = 0, held = 0, open = 0, open_names = {} }
    local goals = type(step) == "table" and step.goals or nil
    if type(goals) ~= "table" then return out end
    for i = 1, #goals do
        local g = goals[i]
        if type(g) == "table" then
            local is_held = false
            if type(held) == "function" then
                local ok, v = pcall(held, i, g)
                is_held = ok and v ~= nil and v ~= false
            end
            if g.is_complete == true then
                out.done = out.done + 1
            elseif is_held then
                out.held = out.held + 1
            else
                out.open = out.open + 1
                if #out.open_names < GOAL_LIST_MAX then
                    out.open_names[#out.open_names + 1] = goal_label(g, i)
                end
            end
        end
    end
    return out
end

--- Every step read, from quest/guide.lua refresh(). `step` is the plain step
--- table (num / is_complete / goals) or nil; `held` is the optional hold test.
function D.step(step, held)
    if not D.ON then return end
    if type(step) ~= "table" then return end
    reads = reads + 1
    local num = tonumber(step.num) or 0
    if last_step ~= nil and num ~= last_step then
        step_changes = step_changes + 1
        dirty = true
        -- The ledger of the step we are LEAVING, as it stood on its last read.
        local was = last_step_goals or { done = 0, held = 0, open = 0, open_names = {} }
        local how
        if was.open > 0 then
            left_open = left_open + 1
            how = string.format("%d goal(s) STILL OPEN: %s", was.open,
                #was.open_names > 0 and table.concat(was.open_names, "; ") or "?")
        elseif was.done > 0 or was.held > 0 then
            how = (was.held > 0) and "every goal complete or held by the bot" or "all goals complete"
        else
            how = "no goals were read for it"
        end
        trail("step %s -> %s after %d done / %d held / %d open - %s", tostring(last_step),
            tostring(num), was.done, was.held, was.open, how)
        last_goal_key = nil
    end
    last_step = num
    last_step_goals = ledger(step, held)
end

--- The goal the engine is working, from quest/guide.lua guide.goal().
function D.goal(goal)
    if not D.ON then return end
    local key
    if type(goal) ~= "table" then
        key = "none"
    else
        key = string.format("%s|%s|%s", tostring(goal.index or goal.num or "?"),
            tostring(goal.action or "?"), tostring(goal.text or goal.quest_id or "-"))
    end
    if key == last_goal_key then return end
    local first = last_goal_key == nil
    last_goal_key = key
    if first then return end                 -- the first goal of a step is not a change
    goal_changes = goal_changes + 1
    dirty = true
    trail("step %s goal -> %s", tostring(last_step), key)
end

--- Every arrow read, from quest/guide.lua refresh(). `kind` is the type string
--- (or nil for no arrow) and `used` says whether it was stored as a walk target.
function D.arrow(kind, used)
    if not D.ON then return end
    local k = tostring(kind or "none")
    if k == "" then k = "(blank)" end
    if arrows[k] == nil then
        arrows[k] = 0
        arrow_order[#arrow_order + 1] = k
    end
    arrows[k] = arrows[k] + 1
    if used == false then dirty = true end
end

--- The product's own corpse run started (death.lua), which is what actually
--- walks to the body - from core.game_ui.get_corpse_position, never the guide.
function D.corpse_run(why)
    if not D.ON then return end
    corpse_runs = corpse_runs + 1
    dirty = true
    trail("corpse run %d started (%s) - the bot's own, from get_corpse_position, "
        .. "not a guide waypoint", corpse_runs, tostring(why or "death"))
end

local function arrow_tally()
    local parts = {}
    for i = 1, #arrow_order do
        local k = arrow_order[i]
        parts[#parts + 1] = string.format("%s %d", k, arrows[k])
    end
    return #parts > 0 and table.concat(parts, ", ") or "none seen"
end

--- Called from the update tick. Writes at most one line per SUMMARY_GAP, and
--- only when something changed.
function D.tick()
    if not D.ON then return end
    local t = now()
    if t <= 0 then return end
    if next_summary == 0 then
        next_summary = t + SUMMARY_GAP
        return
    end
    if t < next_summary then return end
    next_summary = t + SUMMARY_GAP
    if not dirty then return end
    dirty = false
    local held = last_step_goals and last_step_goals.held or 0
    trail("summary: step %s, %d reads, %d step changes (%d left open goals), "
        .. "%d goal changes, %d held now, %d corpse runs | arrows: %s",
        tostring(last_step), reads, step_changes, left_open, goal_changes, held,
        corpse_runs, arrow_tally())
end

--- Start / Stop and the tests.
function D.reset()
    arrows, arrow_order = {}, {}
    reads, step_changes, goal_changes, left_open, corpse_runs = 0, 0, 0, 0, 0
    last_step, last_step_goals, last_goal_key = nil, nil, nil
    next_summary, dirty = 0, false
end

--- The counters, for the tests and the GUI.
function D.counts()
    return { reads = reads, step_changes = step_changes, goal_changes = goal_changes,
        left_open = left_open, corpse_runs = corpse_runs, step = last_step,
        held = last_step_goals and last_step_goals.held or 0,
        arrows = arrows, arrow_tally = arrow_tally() }
end

return D
