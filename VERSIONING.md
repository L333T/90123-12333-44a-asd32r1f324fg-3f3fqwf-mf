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
| 1.4.4 | Vendor food/drink buying (`supplies.lua`) - the API reference confirmed `core.input.buy_item` and `core.game_ui.get_vendor_item_info` exist, correcting the v1.4.3 claim. Fixed: auto-equip never confirmed the bind-on-equip prompt, so BoE upgrades were re-issued forever and never worn. |
| 1.4.5 | Hunter, Warlock, Shaman and Rogue rotations plus shared `pets.lua`. All nine classes now supported. Resolves NEXT_FEATURES 5.3 (weapon enchants) and 5.4 (pets). Rogue poison *application* still has no API. |
| 1.4.6 | Eat/drink: one consumable at a time. Added a 5s commit window (aura latency was double-consuming), split the shared food/drink timer, capped uses per rest and warn when an aura id is missing instead of silently eating the stack. |
| 1.4.7 | Rest now outranks looting in the tick cascade - loot.tick returning true every tick while a corpse was in range meant healing.tick was never reached and the bot never ate or drank. Added resting guards to loot.tick, rotation.tick and rotation.buffs_ooc. |
