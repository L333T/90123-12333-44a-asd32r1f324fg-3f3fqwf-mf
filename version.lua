-- ============================================================================
-- restedXP_questing
-- Identity — single source of truth for name / authors / version
-- ============================================================================
-- Version: 4.30.1
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
return {
    name = "restedXP_questing",
    short_tag = "restedXP_questing",
    description = "Intelligent fully AFK WoW leveling bot",
    authors = "BLIZZ - Anthonyk",
    author = "BLIZZ - Anthonyk",
    version = "4.30.1",
    folder = "restedXP_questing",
}
