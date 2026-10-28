-- ============================================================================
-- restedXP_questing
-- Identity — single source of truth for name / authors / version
-- ============================================================================
-- Version: 4.37.0
-- 4.37.0 (user: "use A* + rays alongside Sentinel navigation to improve player navigation"): the local A* + ray fallback (movement/astar.lua, ported from Zygor) runs alongside Sentinel - when a Sentinel walk ends "arrived" short of its goal or "unreachable" within 15 yd, a short local grid path is searched with game raycasts and walked leg by leg through Sentinel move_direct. General tab "Local A* Fallback" (mfg_astar), on by default; AS.ON kill switch, per-frame ray budget, self-check, off for the session after repeated ray/height errors. Sentinel is never replaced - this is additive.
-- 4.31.2: the added questing data tables are removed (the Master Farmer database mfdb, data/quest_items, data/zygor_use_items) - the freeze on quest pickup / NPC interaction: their megabyte strings were decoded by the build's string obfuscation on first load.
-- 4.31.1: game freeze on NPC interaction fixed - the first repairer / flight master / battlemaster search converted every database spawn (up to 1356) with get_world_pos_from_map_pos in one frame; now the player's continent only, at most 40 conversions and 800 rows a frame (mfdb.services_world), the quest-item index a slice a frame.
-- 4.31.0: the ray walk assistant (movement/trace.lua from Desktop Helper trace.lua; user lifted the ray rule): Sentinel walking with no progress and the way ahead blocked - a low obstacle is jumped, a wall gets a Sentinel avoidance zone and a soft re-plan (the blind indoor jump only when rays are off).
-- 4.30.2: repeated countdown status lines (spellbook wait, corpse walk, approach) print at most every 5 s.
-- 4.30.1 (Desktop Helper): profession tools (picks, knives, hammer, poles) and Golden
-- Pearl are never sold; a swift mount item beats a slow class mount.
-- 4.30.0 (Desktop items_db): Healthstones at the potion line, 3 foods / drinks added;
-- the repair search falls back to the Master Farmer database's repairers /
-- innkeepers (mfdb.lua, data/mfdb_*) when none seen is nearer.
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
-- 4.32.0: the ray helpers (movement/trace.lua) gain the Orca A* port's logic (user 2026-10-26): hit_z (8-step impact height), ground_z (height query, else a ray snap), a jump only with headroom over the obstacle and no drop past 6 yd behind it (else an avoidance zone), a corner snag at the side gets a small zone.
-- 4.32.1: manifest.lua regenerated - it still listed the 4.29.0 files, so movement/trace.lua (new in 4.31.0) was never downloaded and movement, loot, death, healing, vendor, path_runner and the quest pack failed to load.
-- 4.33.0: swing timer from the combat log (swingtimer.lua): SWING_DAMAGE / SWING_MISSED of the player and pet; melee weaving (adapt.swing_ok), the spell-damage swing filter and the swing watch use it - auto_attack_helper's last attack moved only on the Attack command.
-- 4.34.0: quests started and finished with bag items (quest/bagstart.lua): a use goal that names no item takes the step's own item (with a use spell, or a quest starter - quest class, no use spell - while the step accepts a quest), the quest panel the item opens is accepted; an accept whose step uses an item is started from the bags before any NPC search.
-- 4.35.0: TBC spell database (data/tbc_spells, tools/gen_tbc_spells.py): on TBC Anniversary the spellbook scan also asks about every id of this class (Mage conjures, Shaman totems) and the race's racials for this class, so the Spells tab lists every spell the character knows; only this class's file and the racial table load, once, and are freed.
-- 4.36.0: the wall-gap scan from the Orca A* port (_howManyLeft / _howManyRight, Auto BG 2.39.0): a wall ahead of a stalled Sentinel walk is measured to both sides one look later (movement/trace.lua gap_counts), and small avoidance zones go along its long side only, so the re-plan goes round the short end; equal or unmeasured sides keep the single zone ahead.
-- 4.38.0: the GUI window id no longer carries the product version (user 2026-10-27: "Product versions have changed, GUI resolution is no longer applied"). Every release minted a NEW core.menu.window id, so the saved window size / position / active tab were dropped and the window reopened at the hard-coded 1100 x 640 1080p default while mf_skin drew the artwork at the screen's real pixel scale. The id is fixed now (as mf_route_tool has always had), and a window opened for the first time takes mf_skin.window_px for this screen. This release migrates the id once - the window starts fresh a final time, then keeps its geometry.
-- 4.39.0: check_path (advanced Sentinel API, user 2026-10-27): while a walk of ours runs, the path Sentinel is following is validated every 3 s and an unambiguous "no longer valid" takes a fresh path at once instead of waiting for the walk to stall into the stuck ladder. nav_client:check_path is present on v0.24 but its callback shape is NOT recorded, so the adapter only acts on an explicit valid=false / blocked=true / reachable=false - a bare false (what a server error looks like here) answers "no opinion" and never re-plans; the first answer's shape is logged so the real shape can be read back. Never on a fresh leg or with a path request in flight (the crash rule), never through a hold or a pending stop. 3 throws, or a library without check_path, switch it off for the session.
-- 4.40.0: always dismount for a doorway, measured with the mounted player height
-- (user: "Always dismount when attempting to enter doorways, use get player height
-- when mounted, to check entrances to keep player from getting stuck"). get_height()
-- answers the body we have right now, so mounted it IS the taller body. movement/trace
-- remembers the on-foot height whenever is_mounted() is false and, while mounted,
-- probes 1 / 2 / 3 yd ahead at three heights: clear at the waist and at the on-foot
-- head (the player fits) but blocked at the mounted head (the mount does not) is a
-- doorway, and movement/mount M.dismount takes us off at once and suppresses mounting
-- for 8 s so M.step does not put us straight back into it. Blocked at the waist too is
-- a WALL, left to the wall logic, and a flying mount is never dismounted in the air.
-- The check runs while the walk is still MOVING, unlike the jump / wall checks which
-- only look after a stall: the point is to be short before the doorway rather than to
-- notice after being wedged in it. Sentinel is not stopped for it and keeps its path.
-- 4.41.0: the Sentinel kite retreat survives a target switch (found in Zygor
-- Questing 1.42.0; movement/combat.lua is shared, so the bug was here too).
-- combat_engage's per-target reset zeroed st.retreat_until and st.kite_pending, so
-- the hold above the "range <= reach" branch stopped applying and the kite walk was
-- stopped as "in range" on the new attacker about a second after it started - which
-- in a multi-mob fight is continuously. nav_client:kite was answering all along; the
-- retreat was simply being thrown away. A retreat is about where the PLAYER needs to
-- be, not which unit is being hit, so it now outlives the switch and ends on its own
-- RETREAT_TIME. The latch and band state still reset per target.
return {
    name = "restedXP_questing",
    short_tag = "restedXP_questing",
    description = "Intelligent fully AFK WoW leveling bot",
    authors = "BLIZZ - Anthonyk",
    author = "BLIZZ - Anthonyk",
    version = "4.41.0",
    folder = "restedXP_questing",
}
