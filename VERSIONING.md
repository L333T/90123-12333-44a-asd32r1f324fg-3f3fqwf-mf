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
| 1.4.8 | Fixed: the v1.4.6 per-rest use cap (`MAX_USES = 8`) was only ever cleared by `clear_rest()`, which runs on player-nil, toggle-off and swimming - never on a rest that simply finished. The counter therefore accumulated across the whole session and eating and drinking stopped permanently after eight consumables. The budget is now cleared wherever a rest latch drops. |
| 1.4.9 | Eat/drink could stall with no output at all. `use_self_safe` applies nine gates by default and one of them is the global cooldown, which food and drink do not use - a rest entered straight after a kill was refused for the whole GCD. `use_first` returned a bare `false`, `consume_one` swallowed it, and `healing.tick` still reported "resting", so the bot sat doing nothing and logged nothing. Now: `skip_gcd` is passed, a refused use falls back to the unguarded `use_self`, every failure is named in a warning once per rest, and `mfg_rest_debug` prints the single gate currently blocking a rest. Also hardened the module-load item prewarm, which called `izi.item` unguarded ~250 times - one throw would have failed the chunk and taken the whole bot down with it. |
| 1.5.0 | Quest dialog handling rewritten against the real `core.quests` surface. Three defects: (1) `complete_quest()` and `get_quest_reward(0)` were called in sequence, but they are alternatives - `get_quest_reward(i)` selects choice i *and* completes - so a quest offering a choice of rewards could never be handed in; the reward is now chosen by vendor value and `complete_quest()` is used only when there is no choice. (2) `confirm_accept_quest()` was never called, so escort / auto-accept quests stalled on their confirmation popup. (3) Only the gossip frame was handled; an NPC showing the quest *greeting* frame (indexed, via `get_available_title` / `select_available_quest`) fell through to a bare `accept_quest()` with nothing selected. `decline_quest`, `abandon_quest`, `add_quest_watch` and the trainer calls exist but have no caller in this bot and were deliberately left unused. |
| 1.5.1 | Quest rewards were never chosen. `go_and_interact` re-issued `interact_with_object` every 1.2s while the bot stood at the NPC, and the dialog steps only ran on the tick that fired - but re-interacting tears down the open frame, so the reward frame never survived long enough for `get_quest_item_link` to report a choice. Every hand-in fell through to `complete_quest()`, which the client refuses while a choice is pending, and the quest stayed in the log for ever. Walking to the NPC (`npc.at_npc`) and driving the dialog (`npc.accept` / `npc.turn_in`) are now separate; each dialog is a tick-driven state machine that interacts ONCE, waits for the frame, reads the choices, picks one and verifies the quest left the log, retrying up to three times before warning. Reward choice is now rated by `equip.rate`: a usable upgrade beats a usable item, beats a non-equippable one, beats something the class cannot use, with vendor price only breaking ties. Added the class weapon-proficiency and numeric armour tables that make "usable" mean something - a Mage no longer takes the plate chest because it sells for more. New `mfg_quest_debug` logs every step and every choice considered. |
| 1.5.2 | The gossip path never worked on TBC. On Classic Era and TBC Classic the legacy client sends no quest id with a gossip list, so `get_gossip_*_quests` fills `quest_id` with the **1-based row index**. The code compared that against a real quest id (never matched) and then passed a real quest id to `select_gossip_*_quest` (addressed a row that does not exist), so nothing was ever selected - the bot only worked when the quest detail frame happened to already be up. Gossip rows are now matched on **title**, with the id comparison kept as a retail fallback, and the opaque handle from the same frame is passed straight back to the selector. `npc.is_complete` had the same bug in its gossip fallback. Also: `entry.is_complete` is declared an integer by the API reference and a boolean by the documentation, so both are accepted, and `-1` (failed) is no longer treated as in-progress. `vendor.lua` was already correct - it matches on `gossip_type` and round-trips `gossip_option_id`. |
