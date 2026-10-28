-- ============================================================================
-- restedXP_questing
-- Identity — single source of truth for name / authors / version
-- ============================================================================
-- Version: 4.0.8
-- Authors: BLIZZ - Anthonyk
-- Folder: restedXP_questing
-- ============================================================================

-- `folder` is the key for NS._sessions, which is how a freshly loaded
-- instance tells an older one still ticking that it has been superseded.
--
-- It deliberately carries NO version. It used to be folder .. "_v" .. version,
-- which meant the key moved on every release: hot-reloading from one version
-- to the next gave the new instance a different key from the old one, so the
-- old one compared itself against a counter nothing was incrementing, never
-- saw itself superseded, and kept ticking alongside the new load. That is
-- exactly the case the counter exists to catch, and it was the one case it
-- could not catch.
--
-- The on-disk folder can be called whatever you like; nothing reads it.
-- 4.0.9: audit phase 1 - the death loop, and a UI reload that was never there.
--   DEATH ZONES (audit F5, from session_2026-10-27_20-56-27.log: the character died
--   6 times in 11 minutes in Zangarmarsh and a zone never armed once - every death
--   logged "death 1 in this area ... 3 needed to avoid it"). A death joined a group
--   only if it was BOTH within JOIN_YARDS (60) AND killed by the SAME npc id, and 3
--   were needed. The log shows both halves failing: deaths 3 and 4 were 27 yd apart
--   in one Bloodscale camp but to different mobs (18089 / 18088), and deaths 4 and 5
--   were the same mob 94 yd apart. A bot dying to a mixed camp or a patrol - the
--   normal case - could never reach 3, so the protection was dead code while the
--   guide re-issued the identical waypoint five times and walked back in. Grouping is
--   AREA ONLY now (the killer npc is still recorded, for the zone's label and for
--   KILLER_PAD) and two deaths are enough. Against that log it arms at death 2 and
--   again at death 4. A repeat death in an area extends the zone that is there
--   instead of stacking a second one on it. tests/test_deathzones_group.lua replays
--   all five real deaths; it fails 18 assertions on the old logic.
--   PERIODIC UI RELOAD REMOVED (audit F1): core.reload_game_ui is declared in NO
--   local stub - absent from all nine .api copies under Documents (2026-10-16 ..
--   2026-10-27), from sylvanas_api/.api and from BLIZZ_PROJECTS/.api, and so are
--   core.reload_plugins and core.reload_scripts. The 30-minute reload and the fifteen
--   safety checks that guarded it therefore never did anything except cost a check
--   per frame. Removed rather than left as a guarded call to a function that is
--   nowhere; the comment in main.lua says how to put it back if a build ever
--   declares one.
--   The stall ladder's rung 2 was "reload the UI, wait 30 s, retry"; it is now the
--   wait and the retry on their own, which is what it was always able to do.
return {
    name = "restedXP_questing",
    short_tag = "restedXP_questing",
    description = "Intelligent fully AFK WoW leveling bot",
    authors = "BLIZZ - Anthonyk",
    author = "BLIZZ - Anthonyk",
    version = "4.0.9",
    folder = "restedXP_questing",
}
