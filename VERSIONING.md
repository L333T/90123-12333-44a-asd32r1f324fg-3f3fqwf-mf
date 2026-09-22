# Master Farmer - Grindbot versioning

Copy-forward. Never rename or delete an old version folder.

## Identity

Canonical fields live in `version.lua`. `header.lua`, the GUI title, and the load log must match that table.

## On a material change

1. Copy `Master_Farmer_Grindbot_vX.Y.Z` to `Master_Farmer_Grindbot_vX.Y.(Z+1)` (or the next semver).
2. Edit **only the new folder**.
3. Update `version.lua`, every `-- Version:` / `-- Folder:` banner, GUI version text, and the load log.
4. Point the Cursor workspace at the new folder.
5. Do not bump for comment-only or rule-only edits.

## Revert

Disable the newer plugin in Sylvanas and enable the older `Master_Farmer_Grindbot_vX.Y.Z` folder.

## History

| Version | Change |
| --- | --- |
| 1.3.38 | movement.lua split into movement/*; HTTP plugin_loader added. Preserved as tag `working-v1.3.38`. |
| 1.4.1 | Priest rotation added and registered. death.lua: killer blacklist, level-gap threat filter, ground-snapped safe-spot candidates. movement.ground_z exported. rotation.lua registry generalised. |
| 1.4.2 | Druid and Paladin rotations added. Paladin aura is one dropdown, not six toggles. Fixed: class heal-threshold sliders were in the checkbox alias table, so `gui.slider` always returned the fallback. Added `gui.combo` and a `combo_aliases` table. |
| 1.4.3 | Auto-equip added (`equip.lua`). Vendor purchasing NOT implemented: the known `core.input`/`core.game_ui` surface exposes no buy function. |
