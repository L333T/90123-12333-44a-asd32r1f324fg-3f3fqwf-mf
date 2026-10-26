-- ============================================================================
-- restedXP_questing
-- Identity — single source of truth for name / authors / version
-- ============================================================================
-- Version: 4.31.2
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
return {
    name = "restedXP_questing",
    short_tag = "restedXP_questing",
    description = "Intelligent fully AFK WoW leveling bot",
    authors = "BLIZZ - Anthonyk",
    author = "BLIZZ - Anthonyk",
    version = "4.32.1",
    folder = "restedXP_questing",
}
