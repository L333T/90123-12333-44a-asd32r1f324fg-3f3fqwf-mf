> **Evidence appendix (2026-10-11, audit of 2.305.0).** Working notes from one audit pass, kept for the per-finding evidence (stub file:line citations, symbol tables, scenarios). Statuses here are as found BEFORE any fix. The current status of every finding, and which ones were re-verified, is in `docs/CODEBASE_AUDIT_REPORT.md`.

# Audit B - core / quest / economy API usage (Master Farmer - Grindbot 2.305.0)

Read-only audit. Nothing in the repo was changed.
Contract used: `C:\Users\ebene\OneDrive\Documents\daaa22\scripts\.api` (core.lua, game_object.lua,
common/izi_sdk.lua, common/utility/inventory_helper.lua, common/enums.lua) plus
`C:\Users\ebene\Downloads\Sylvanas_coreAPI_IZI_API\` (cor_api_input.txt, IZI API/inventory-helper).
(AGENTS.md names `...\3cf70445e7\scripts\.api` as the stub folder; per the task the daaa22 copy was used.)

Files covered: quest/{engine,guide,npc,mismatch,api_examples}.lua, quest.lua, vendor.lua, trainer.lua,
gossip.lua, loot.lua, bags.lua, equip.lua, supplies.lua, resting.lua, healing.lua, conjure.lua,
gather.lua, gather/*.lua, grind.lua, grind/{engine,catalog,zone_lookup}.lua, professions.lua,
data/taxi_nodes.lua (data only - no API calls). Flight / taxi code lives in quest/engine.lua.

## Summary of method
* Every `core.*` symbol in scope was grepped and looked up in core.lua (101 distinct symbols).
* Every `:method(` in scope was checked against game_object.lua fields, then izi_sdk.lua / utility
  stubs (inventory_helper, spell_sequence_helper, movement_handler, vec2/vec3).
* Every `izi.*` symbol was checked in izi_sdk.lua (all 17 declared).
* Index bases checked: loot (0-based, stub 1452-1458) - all three loops correct; vendor rows /
  buy_item (1-based, stub 1834 + cor_api_input.txt:1287) - correct; taxi nodes (1-based, stub
  2552) - correct; gossip option / gossip quest ids (round-trip, never stored) - correct;
  quest log indices (1..get_num_quest_log_entries) - correct; get_quest_log_leader_board
  (obj_index, quest_log_index) order - correct; get_num_bag_slots(bag+1) vs get_items_in_bag(bag)
  shift - correct everywhere; get_item_durability slot 1..19 - correct.
* No `.` vs `:` mistakes found on core / izi / helper calls (inventory_helper uses `:`,
  izi.sequence:cancel_all() matches `function spell_sequence_helper:cancel_all()`).

## (a) API symbol table

### core.* (declared line in core.lua; uses; first 4 shown)
| symbol | declared? | used in | 
|---|---|---|
| `core.addons.rested_xp` | core.lua:7632 | quest/api_examples.lua:19 quest/guide.lua:379  |
| `core.character.is_swimming` | core.lua:2337 | resting.lua:861 gather/mount.lua:105  |
| `core.game_ui.get_current_map_id` | core.lua:1762 | quest/mismatch.lua:97 gather/engine.lua:176  |
| `core.game_ui.get_loot_item_count` | core.lua:1454 | quest/engine.lua:3031 loot.lua:516 gather/engine.lua:454  |
| `core.game_ui.get_pending_equip_slot` | core.lua:1435 | quest/engine.lua:828 equip.lua:699 equip.lua:767  |
| `core.game_ui.get_vendor_item_count` | core.lua:1841 | quest/engine.lua:706 vendor.lua:372 vendor.lua:1561 equip.lua:728 (+3 more) |
| `core.game_ui.get_vendor_item_info` | core.lua:1835 | quest/engine.lua:709 supplies.lua:125 gather/supply.lua:126  |
| `core.game_ui.get_world_pos_from_map_pos` | core.lua:1540 | quest/guide.lua:2569-2570 (via local alias `gui`) |
| `core.game_ui.has_cursor_item` | core.lua:1444 | equip.lua:703  |
| `core.get_exact_game_version` | core.lua:511 | quest/api_examples.lua:37 quest/npc.lua:351  |
| `core.get_game_version` | core.lua:505 | quest/api_examples.lua:41 quest/npc.lua:353 gather/route.lua:37  |
| `core.get_map_id` | core.lua:368 | quest/engine.lua:2737  |
| `core.input.buy_item` | core.lua:3042 | quest/engine.lua:931 supplies.lua:336 gather/supply.lua:280  |
| `core.input.clear_cursor` | core.lua:2989 | equip.lua:704  |
| `core.input.close_loot` | core.lua:3661 | quest/engine.lua:3051 loot.lua:532 gather/engine.lua:487  |
| `core.input.close_merchant` | core.lua:3060 | quest/engine.lua:760 quest/engine.lua:882 quest/engine.lua:2251 quest/npc.lua:474 (+2 more) |
| `core.input.descend_start` | core.lua:3629 | quest/engine.lua:3005  |
| `core.input.descend_stop` | core.lua:3635 | quest/engine.lua:3006  |
| `core.input.destroy_container_item` | core.lua:2936 | quest/engine.lua:819 vendor.lua:519  |
| `core.input.dismount` | core.lua:3648 | resting.lua:1041 gather/engine.lua:313 gather/engine.lua:512 gather/supply.lua:347  |
| `core.input.equip_container_item` | core.lua:2973 | quest/engine.lua:825 equip.lua:698  |
| `core.input.equip_pending_item` | core.lua:3005 | quest/engine.lua:830 equip.lua:701 equip.lua:770  |
| `core.input.interact_with_object` | core.lua:3376 | quest/engine.lua:955 quest/engine.lua:1185 quest/engine.lua:2273 quest/engine.lua:2600 (+10 more) |
| `core.input.jump` | core.lua:3611 | quest/engine.lua:3018  |
| `core.input.loot_item` | core.lua:3655 | quest/engine.lua:3049 loot.lua:530 gather/engine.lua:459  |
| `core.input.loot_object` | core.lua:3348 | loot.lua:720  |
| `core.input.mount` | core.lua:3642 | gather/mount.lua:127  |
| `core.input.repair_all_items` | core.lua:3047 | vendor.lua:1632  |
| `core.input.stop_attack` | core.lua:3211 | quest/engine.lua:3678 resting.lua:511 grind/engine.lua:715  |
| `core.input.use_container_item` | core.lua:2900 | vendor.lua:701 bags.lua:123  |
| `core.input.use_item` | core.lua:2868 | bags.lua:138  |
| `core.input.use_object` | core.lua:3365 | quest/engine.lua:3120 gather/engine.lua:529  |
| `core.inventory.can_merchant_repair` | core.lua:1214 | vendor.lua:376 vendor.lua:1138 vendor.lua:1562 vendor.lua:1598  |
| `core.inventory.get_bag_inventory_slot` | core.lua:1407 | vendor.lua:264 equip.lua:600  |
| `core.inventory.get_gold` | core.lua:1245 | quest/api_examples.lua:372 quest/engine.lua:911 quest/engine.lua:918 quest/engine.lua:1128 (+10 more) |
| `core.inventory.get_item_durability` | core.lua:1228 | vendor.lua:353  |
| `core.inventory.get_items_in_bag` | core.lua:1107 | quest/guide.lua:2411 vendor.lua:197 vendor.lua:249 vendor.lua:298 (+3 more) |
| `core.inventory.get_num_bag_slots` | core.lua:1157 | vendor.lua:193 vendor.lua:297 vendor.lua:333 bags.lua:65 (+1 more) |
| `core.inventory.get_total_repair_cost` | core.lua:1201 | vendor.lua:1599  |
| `core.object_manager.get_all_objects` | core.lua:3778 | gather/scan.lua:91  |
| `core.object_manager.get_object_from_guid` | core.lua:3827 | loot.lua:168  |
| `core.object_manager.get_visible_objects` | core.lua:3791 | quest/guide.lua:73 resting.lua:613  |
| `core.quests.abandon_quest` | core.lua:6118 | quest/api_examples.lua:334 quest/npc.lua:560  |
| `core.quests.abandon_quest_by_id` | core.lua:6169 | quest/api_examples.lua:325 quest/api_examples.lua:326 quest/npc.lua:548 quest/npc.lua:550  |
| `core.quests.accept_quest` | core.lua:5987 | quest/api_examples.lua:270 quest/npc.lua:1098  |
| `core.quests.buy_trainer_service` | core.lua:6224 | quest/api_examples.lua:379 quest/engine.lua:1150 trainer.lua:665 gather/trainer.lua:133  |
| `core.quests.close_gossip` | core.lua:6202 | quest/api_examples.lua:312 quest/engine.lua:1017 quest/engine.lua:1182 quest/engine.lua:2156 (+8 more) |
| `core.quests.close_quest` | core.lua:5990 | quest/api_examples.lua:311 quest/engine.lua:2569 quest/engine.lua:2599 quest/engine.lua:2879 (+3 more) |
| `core.quests.close_trainer` | core.lua:6232 | quest/api_examples.lua:313 quest/api_examples.lua:314 quest/api_examples.lua:383 quest/api_examples.lua:384 (+6 more) |
| `core.quests.complete_quest` | core.lua:5996 | quest/api_examples.lua:287 quest/npc.lua:1297  |
| `core.quests.confirm_accept_quest` | core.lua:6003 | quest/api_examples.lua:271 quest/npc.lua:1101  |
| `core.quests.expand_quest_header` | core.lua:6068 | quest/api_examples.lua:74 quest/api_examples.lua:114 quest/guide.lua:1151 quest/npc.lua:532 (+1 more) |
| `core.quests.get_active_title` | core.lua:6252 | quest/api_examples.lua:358 quest/npc.lua:599 quest/npc.lua:873  |
| `core.quests.get_available_level` | core.lua:6267 | quest/npc.lua:798  |
| `core.quests.get_available_title` | core.lua:6257 | quest/api_examples.lua:360 quest/npc.lua:600 quest/npc.lua:793 quest/npc.lua:871  |
| `core.quests.get_gossip_active_quests` | core.lua:6191 | quest/api_examples.lua:240 quest/engine.lua:2202 quest/guide.lua:2174 quest/npc.lua:665 (+3 more) |
| `core.quests.get_gossip_available_quests` | core.lua:6187 | quest/api_examples.lua:218 quest/engine.lua:2201 quest/guide.lua:2175 quest/npc.lua:663 (+1 more) |
| `core.quests.get_gossip_options` | core.lua:6179 | quest/engine.lua:2186 quest/engine.lua:2416 quest/npc.lua:769 quest/npc.lua:829 (+1 more) |
| `core.quests.get_item_info` | core.lua:6247 | quest/api_examples.lua:406 quest/guide.lua:2421 vendor.lua:273 vendor.lua:464 (+7 more) |
| `core.quests.get_item_spell` | core.lua:6242 | quest/api_examples.lua:394 bags.lua:234 resting.lua:301 resting.lua:302  |
| `core.quests.get_num_quest_choices` | core.lua:6175 | quest/api_examples.lua:296 quest/api_examples.lua:297 quest/npc.lua:940 quest/npc.lua:941  |
| `core.quests.get_num_quest_leader_boards` | core.lua:6079 | quest/api_examples.lua:145 quest/guide.lua:1226 quest/npc.lua:1472  |
| `core.quests.get_num_quest_log_entries` | core.lua:6015 | quest/api_examples.lua:96 quest/api_examples.lua:115 quest/guide.lua:1153 quest/npc.lua:398 (+4 more) |
| `core.quests.get_num_trainer_services` | core.lua:6210 | quest/api_examples.lua:368 quest/engine.lua:1057 quest/engine.lua:1108 quest/engine.lua:2225 (+3 more) |
| `core.quests.get_open_quest_info` | core.lua:6026 | quest/api_examples.lua:162 quest/api_examples.lua:165 quest/npc.lua:360 quest/npc.lua:361  |
| `core.quests.get_quest_item_link` | core.lua:6285 | quest/npc.lua:594 quest/npc.lua:913  |
| `core.quests.get_quest_log_leader_board` | core.lua:6085 | quest/api_examples.lua:147 quest/guide.lua:1231 quest/npc.lua:1476  |
| `core.quests.get_quest_log_quest_ids` | core.lua:6159 | quest/api_examples.lua:76 quest/api_examples.lua:77 quest/guide.lua:1146 quest/npc.lua:388 (+1 more) |
| `core.quests.get_quest_log_title` | core.lua:6039 | quest/api_examples.lua:98 quest/api_examples.lua:117 quest/guide.lua:1158 quest/npc.lua:400 (+3 more) |
| `core.quests.get_quest_objectives` | core.lua:6140 | quest/api_examples.lua:133 quest/api_examples.lua:134 quest/guide.lua:1209 quest/guide.lua:1210  |
| `core.quests.get_quest_reward` | core.lua:6000 | quest/api_examples.lua:303 quest/api_examples.lua:306 quest/npc.lua:1343 quest/npc.lua:1352  |
| `core.quests.get_trainer_service_cost` | core.lua:6220 | quest/api_examples.lua:375 quest/engine.lua:1064 trainer.lua:252 gather/trainer.lua:129  |
| `core.quests.get_trainer_service_info` | core.lua:6215 | quest/api_examples.lua:374 quest/engine.lua:1060 trainer.lua:258 gather/trainer.lua:126  |
| `core.quests.is_gossip_frame_shown` | core.lua:6206 | quest/api_examples.lua:199 quest/engine.lua:2121 quest/engine.lua:2557 quest/engine.lua:2788 (+2 more) |
| `core.quests.is_on_quest` | core.lua:6049 | quest/api_examples.lua:58 quest/api_examples.lua:61 quest/engine.lua:1467 quest/engine.lua:1531 (+5 more) |
| `core.quests.is_quest_complete` | core.lua:6151 | quest/api_examples.lua:64 quest/api_examples.lua:65 quest/npc.lua:369 quest/npc.lua:370  |
| `core.quests.is_quest_flagged_completed` | core.lua:6044 | quest/api_examples.lua:57 quest/engine.lua:1472 quest/engine.lua:1506 quest/engine.lua:1532 (+2 more) |
| `core.quests.select_active_quest` | core.lua:6271 | quest/api_examples.lua:345 quest/npc.lua:881  |
| `core.quests.select_available_quest` | core.lua:6275 | quest/api_examples.lua:347 quest/npc.lua:879  |
| `core.quests.select_gossip_active_quest` | core.lua:6199 | quest/api_examples.lua:281 quest/npc.lua:681  |
| `core.quests.select_gossip_available_quest` | core.lua:6195 | quest/api_examples.lua:263 quest/npc.lua:679  |
| `core.quests.select_gossip_option` | core.lua:6183 | quest/api_examples.lua:208 quest/engine.lua:2219 gossip.lua:121  |
| `core.quests.select_quest_log_entry` | core.lua:6062 | quest/api_examples.lua:332 quest/npc.lua:558  |
| `core.quests.set_abandon_quest` | core.lua:6114 | quest/api_examples.lua:333 quest/npc.lua:559  |
| `core.reload_game_ui` | NOT DECLARED | quest/engine.lua:1634 quest/engine.lua:1635 quest/engine.lua:2498 quest/engine.lua:2500 (+1 more) |
| `core.skill.expand_trainer_skill_line` | core.lua:8900 | quest/engine.lua:1112 trainer.lua:627 gather/trainer.lua:122  |
| `core.skill.get_num_skill_lines` | core.lua:8854 | professions.lua:36  |
| `core.skill.get_skill_line_info` | core.lua:8876 | professions.lua:38  |
| `core.spell_book.get_mount_count` | core.lua:4214 | gather/mount.lua:51  |
| `core.spell_book.get_mount_info` | core.lua:4221 | gather/mount.lua:54  |
| `core.spell_book.get_profession_info` | core.lua:4529 | gather/route.lua:54 professions.lua:54  |
| `core.spell_book.get_professions` | core.lua:4509 | gather/route.lua:49 professions.lua:49 professions.lua:83  |
| `core.spell_book.has_spell` | core.lua:4046 | conjure.lua:118  |
| `core.spell_book.is_spell_known` | core.lua:4060 | conjure.lua:119  |
| `core.spell_book.is_usable_spell` | core.lua:3939 (---@field on spell_book class) | conjure.lua:258  |
| `core.taxi.close` | core.lua:2616 | quest/engine.lua:2255 quest/engine.lua:2520 quest/engine.lua:2551 quest/engine.lua:2672 (+1 more) |
| `core.taxi.node_name` | core.lua:2564 | quest/engine.lua:2344 quest/engine.lua:2392 quest/engine.lua:2529 quest/engine.lua:2683  |
| `core.taxi.node_type` | core.lua:2596 | quest/engine.lua:2357 quest/engine.lua:2390 quest/engine.lua:2687  |
| `core.taxi.num_nodes` | core.lua:2554 | quest/engine.lua:2229 quest/engine.lua:2336 quest/engine.lua:2678 quest/engine.lua:2770  |
| `core.taxi.take_node` | core.lua:2606 | quest/engine.lua:2532 quest/engine.lua:2778  |
| `core.time` | core.lua:312 | quest/mismatch.lua:71  |
| `core.trade_skill.get_num_primary_professions` | core.lua:8471 | professions.lua:80  |

Notes on the core table
* `core.reload_game_ui` - undeclared, intentional per AGENTS.md; every call is `type(...) == "function"` gated + pcall (engine.lua:1634, 2498). INFO only.
* `core.spell_book.is_usable_spell` - declared as a `---@field` (core.lua:3939, note at 3975), not as a function body; fine.
* `core.addons.rested_xp.*` - read through `ns_call(name)` in quest/guide.lua:373-394 (is_loaded, has_current_step, get_current_step, get_current_stickies, get_objectives, get_current_waypoint, get_step_waypoints, skip_current_step - all declared core.lua:7636-7682). Field reads in plain_goal / plain_step / plain_waypoint / plain_objective (guide.lua:229-327) match rested_xp_goal_info / step_info / waypoint_info / objective_info (core.lua:7581-7626) exactly.
* "core.lua" hits in the grep are comments only.

### game_object methods (game_object.lua field lines)
| method | declared? | notes |
|---|---|---|
| is_valid, get_guid, get_name, get_position, get_npc_id, get_npc_flags, get_item_id, get_level, get_class, get_race_id, get_creature_type, is_dead, is_ghost, is_player, is_unit, is_mounted, is_indoors, is_outdoors, is_in_combat, is_moving, is_flying, can_attack, is_enemy_with, get_health, get_target, get_pet, get_buffs, get_item_stack_count, get_item_at_inventory_slot, has_loot, can_be_looted, can_be_used | yes (game_object.lua:105-532) | get_npc_flags bits used (0x2 questgiver, 0x20 class trainer, 0x40 profession trainer, 0x80 vendor, 0x1000 repair, 0x2000 flight master) all match game_object.lua:514-519 |
| get_class_id | NOT DECLARED | conjure.lua:85 - fallback only when get_class() is not a number, pcall-guarded (CORE-B-12) |
| distance_to, get_health_percentage, get_health_percentage_inc, has_buff, has_aura, is_dead_or_ghost, is_channeling_or_casting, max_health | izi extensions (izi_sdk.lua:72-318) | get_health_percentage is 1..100 (CORE-B-3) |
| count, in_inventory, cooldown_up, name, use_self, use_self_safe | izi_item (izi_sdk.lua:619-633) | |
| cast_safe, cast_time_ms, cooldown_up | izi_spell (izi_sdk.lua:357-465) | |
| get_character_bag_slots, get_total_free_slots, get_current_consumables_list, update_consumables_list | inventory_helper (`:`) | correct colon calls |
| cancel_all | spell_sequence_helper (`function spell_sequence_helper:cancel_all()`) | resting.lua:518 correct |
| pause_movement_light | movement_handler (`:`) | loot.lua:722 correct |
| dist_to | vec2 / vec3 | |
| select (gossip_option_view / gossip_quest_view `:select()`) | izi_sdk.lua:1104, 1116 | gossip.lua / npc.lua correct |

### izi.* (all declared in izi_sdk.lua)
izi.me 584, izi.now 607, izi.item 613, izi.spell 578, izi.enemies_if 598, izi.on_combat_finish 564,
izi.get_terrain_height 1282, izi.use_best_health_potion_safe 654, izi.use_best_mana_potion_safe 655,
izi.is_sequence_active 1449, izi.cancel_sequence 1451, izi.sequence 1442, izi.gossip 1155
(.is_open, .close, .ICON, .options, .find_option_by_icon, .available_quests, .active_quests: 1137-1146).

## (b) Findings

### CORE-B-1 | High | confidence Medium-High (stub internally inconsistent; the newer notes agree) | bags.lua:87
Excerpt:
```lua
and s.bag_slot >= 1 and s.bag_slot <= (caps[s.bag_id] or 0) then
```
with `caps[0] = 16` (bags.lua:60-68) and `caps[b] = get_num_bag_slots(b+1)` for worn bags.
* Actual vs expected: bags.list keeps a helper row only when `bag_slot` is in `1..capacity`. The
  core documents the container-action slot (= inventory_helper's `bag_slot`) as WoW's 1-based slot
  PLUS ONE, i.e. `2..capacity+1`. The filter then drops the LAST slot of every bag (backpack
  slot 16 = bag_slot 17; slot n of an n-slot bag = n+1).
* Evidence:
  - core.lua:1172-1173 `slot_id  WoW's slot + 1, which is inventory_helper's bag_slot` / `So backpack slot 16 is (0, 17).`
  - core.lua:1182 loop example `get_container_item_link(bag, wow_slot + 1)` for `wow_slot = 1, n`.
  - core.lua:6835-6836 (mail attach): `the bag slot convention every container action uses: WoW's bag ... and WoW's slot + 1.`
  - cor_api_input.txt:690-694: the raw get_items_in_bag slot_id "is one short of what these functions want".
  - Conflicting older note: core.lua:1092 "for bag 0 that means 1 to 16". The three newer notes (2026-10-04) agree with each other and with the helper doc, so the older one is most likely stale.
* Runtime scenario: food in backpack slot 16 / the last slot of a worn bag is invisible to
  bags.food_water -> resting reports "nothing usable in the bags" and supplies buys more; a grey
  in the last slot is never sold (vendor.sell_one) or deleted (destroy_cheapest_junk); bags.free_slots
  over-reports by one free slot per full bag, so full bags read "4-5 free", no vendor trip
  starts and loot stays on corpses; a RestedXP `.destroy` / `.equip` item in a last slot is
  reported "not in the bags" and the goal is marked done locally (quest/engine.lua:793-797)
  while RestedXP keeps the step gated.
* Recommended fix: verify once in game (log `bag_id, bag_slot, global_slot` of a full backpack;
  expect 2..17 if the newer docs are right), then accept `s.bag_slot >= 2 and s.bag_slot <= cap + 1`.
  Keep an upper bound: it is the only filter for the bank-storage rows the 2.184.0 comment describes.
* Callers: bags.list -> bags.count, bags.food_water(_count), bags.extra_food_water, bags.free_slots,
  bags.item_at; vendor.lua sell_one / helper_count / destroy_cheapest_junk / bag_free;
  equip.lua find_upgrade / equip_one_bag / attempt verify; quest/engine.lua IS.goal, bag_count (buy step);
  supplies.lua restock; resting.lua bag_present.
* Regression risk: Medium - widening by one must not admit bank rows (they sit far above cap+1 per the 2.184.0 log, "slot 61-72").

### CORE-B-2 | Medium | confidence Medium | quest/guide.lua:2440-2467
Excerpt:
```lua
if pcall(function() input.use_item_target(entry.object, target) end) then return true end
if iid and pcall(function() input.use_item_target(iid, target) end) then return true end
...
if pcall(function() input.use_item(entry.object) end) then return true end
```
* Actual vs expected: passes a game_object where the stub declares an integer item id, and treats
  "no Lua error" as "a use was issued", ignoring the documented boolean result.
* Evidence: core.lua:2865-2868 `function core.input.use_item(item_id)` `---@param item_id integer` `---@return boolean`;
  core.lua:2872-2875 `use_item_target(item_id, target)` `---@param item_id integer` `---@return boolean`.
  The comment at guide.lua:2403 ("core.input.use_item wants the object, not an id") contradicts the stub.
* Runtime scenario: if the binding does not raise on a userdata first argument (coerces to 0 / returns
  false), the first pcall succeeds, use_bag_item returns true, the id path is never tried, and
  quest/engine.lua item_goal (2903) shows "Guide: use X" and retries every ACT_GAP without the item
  ever being used. Even on the id path a `false` return (out of range, cooldown) counts as success.
* Recommended fix: call with `iid` only (`use_item_target(iid, target)` / `use_item(iid)`) and
  return `res == true`.
* Callers: quest/engine.lua:2903 (item_goal).
* Regression risk: Low.

### CORE-B-3 | Medium | confidence High (CONFIRMED against the izi doc) | healing.lua:48-58, resting.lua:237-255
Excerpt:
```lua
if value >= 0 and value <= 1.5 then return value * 100 end
```
fed by `player:get_health_percentage()`.
* Actual vs expected: izi returns 1..100. A real health of 0-1.5 % is multiplied by 100 and read as 0-150 %.
* Evidence: izi_sdk.lua:72 `get_health_percentage fun(self: game_object): number -- 1..100 (e.g., 90 means ~90% HP)`.
* Runtime scenario: in combat at 1.2 % HP healing.tick computes hp = 120, `hp <= hp_pot` is false
  and no health potion is used (unless get_health_percentage_inc happens to return a positive
  forecast); out of combat at 1 % HP resting.lua:781 / 824 sees 100 % and does not eat, so the bot
  pulls the next mob nearly dead.
* Recommended fix: take izi's value as a percentage (clamp 0..100); compute cur/max only when it is nil.
* Callers: healing.tick (potions), resting rest decision (781, 824).
* Regression risk: Low (only the 0-1.5 % band changes).

### CORE-B-4 | Medium | API Verification Required | vendor.lua:371-377, equip.lua:727-731, quest/engine.lua:2225-2226, trainer.lua:599, gather/trainer.lua:168
Excerpt:
```lua
local count = safe(function() return core.game_ui.get_vendor_item_count() end) or 0
if type(count) == "number" and count > 0 then return true end      -- "merchant open"
...
local open = service_count() > 0                                      -- "trainer open"
```
* Actual vs expected: merchant / trainer windows are inferred by polling count readers. The stub
  defines the windows as event spans and never says these counts drop to 0 on close.
* Evidence: core.lua:3049-3058 close_merchant: "this is not an 'is a vendor open' test: the window
  is the span between the MERCHANT_SHOW and MERCHANT_CLOSED events"; core.lua:6227-6231 close_trainer:
  "The window is the span between the TRAINER_SHOW and TRAINER_CLOSED events". core.lua:1838-1841
  get_vendor_item_count and 6208-6210 get_num_trainer_services carry no "0 when closed" guarantee
  (contrast core.taxi.num_nodes, core.lua:2547-2552, and can_merchant_repair, 1205-1214, which do).
* Runtime scenario (if a client keeps the last merchant's count after MERCHANT_CLOSED): vendor.merchant_open()
  stays true after leaving -> vendor.sell_one calls core.input.use_container_item with no merchant,
  which USES the item (eats food, equips a grey, opens a container); equip.tick (727) stays off; the
  quest engine counts the closed merchant as an open frame and marks talk goals done. Same for a
  stale trainer count in trainer.lua.
* Recommended fix: latch MERCHANT_SHOW/CLOSED and TRAINER_SHOW/CLOSED (already registered in
  events.lua:143) and AND them with the count, or confirm in game that both counts read 0 after close.
* Callers: vendor.tick, vendor.merchant_open (quest/engine.lua merchant_up and talk goal), equip.tick,
  trainer.tick, quest/engine.lua prof_goal / talk goal, gather/trainer.lua.
* Regression risk: Medium (core.lua:282-284: a *_CLOSED event may arrive twice - handle idempotently).

### CORE-B-5 | Medium | confidence Medium | supplies.lua:170-190 (carried), quest/guide.lua:2404-2431 (find_bag_item)
Excerpt:
```lua
for bag = 0, 4 do
    local items = safe(function() return core.inventory.get_items_in_bag(bag) end)
```
* Actual vs expected: bag 0 is treated as the backpack; it is the whole player container
  (worn gear, bag objects, backpack, and bank storage on some clients).
* Evidence: core.lua:1042-1050 "BAG 0 DOES NOT MEAN 'THE BACKPACK'. It returns the player's ENTIRE
  item array"; core.lua:1066 "index 23 and up the backpack proper, then bank storage on some clients".
  bags.lua:52-57 records exactly that on this client (bank rows at "bag 0 slot 61-72").
* Runtime scenario: supplies.carried counts food / water / ammo stored in the bank as carried;
  restock takes `have = max(carried, food_water_count)` (supplies.lua:241-246), so the bank stock
  wins and nothing is bought while the bags are empty, and the next rest finds nothing to eat.
  guide.find_bag_item can return a bank (or worn) entry for a quest "use" goal, so the use in
  CORE-B-2 is retried forever on an item that cannot be used.
* Recommended fix: use bags.list / bags.count (inventory_helper, filtered) in both places.
* Callers: supplies.restock (vendor food / water), quest/engine.lua item_goal.
* Regression risk: Low (depends on CORE-B-1, since bags.list is the replacement).

### CORE-B-6 | Low | confidence High | vendor.lua:191-207 (backpack_free), bag_free fallback 324-342
* `#get_items_in_bag(0)` counts worn gear + bag objects + backpack (+ bank) against 16 backpack
  slots, so the fallback always reads 0 free in the backpack. Evidence: core.lua:1042-1050. Only
  reached when izi.me() is nil and inventory_helper:get_total_free_slots fails, so the impact is a
  forced "bags full" vendor trip. Fix: count from bags.list or drop the fallback. Regression risk: Low.

### CORE-B-7 | Low | API Verification Required | quest/mismatch.lua:96-101, gather/engine.lua:176
* `core.game_ui.get_current_map_id()` is used as "the player's current UiMap". The stub gives only
  `--- @return number` (core.lua:1761-1764), placed among the world-map-frame readers
  (is_map_open, get_map_top_left...), so it may be the map the world-map frame shows rather than
  the player's zone. If so, mismatch.check compares RestedXP waypoint UiMap ids with the wrong map
  and holds or releases the step wrongly (gather only logs it).
* Declared alternative: core.game_ui.get_map_at_position(x, y).ui_map_id (core.lua:1544-1562),
  documented as "the most specific UiMap at that point" on the current continent.
* Regression risk: Low.

### CORE-B-8 | Low | API Verification Required | bags.lua:134-140 (use_id), via equip.lua:826 and gather/supply.lua:185
* Gear and ammo are equipped through `core.input.use_item(item_id)`. The stub declares use_item as
  "Use a self cast item" (core.lua:2865-2868); equipping by id is not documented. The documented
  equip path is core.input.equip_container_item (core.lua:2940-2973), already used by
  equip_one_bag and quest IS.goal. gather/supply.lua:185 calls it while the merchant is still open
  (close_merchant follows at 188). The repo's own history (vendor.lua:618-622: use_item "ate the
  bread") suggests it does not sell, so this is a verification item only. AGENTS.md "never sell with
  use_item" is respected: no selling path uses it.

### CORE-B-9 | Low | confidence Medium | quest/guide.lua:1149-1152 (log_index_of)
* `expand_quest_header(0)` runs once per session (headers_expanded latch), but the quest-log walk
  only sees visible rows. Evidence: core.lua:6155-6157 "quests under a header you collapsed can be
  missing; call core.quests.expand_quest_header(0) first if you collapse headers." Scenario: the
  player collapses a zone header mid-session -> guide.log_title and the leader-board fallback in
  objective_names miss that quest. npc.lua expands on every scan; only guide.lua is affected.
  Fix: expand before each walk. Regression risk: Low.

### CORE-B-10 | Low | confidence Medium | professions.lua:34-46
* Skill lines are walked without expanding headers (core.skill.expand_skill_header is declared,
  core.lua:8892), and the walk only sees visible rows. With the Professions header collapsed,
  P.known falls back to core.spell_book.get_professions, which "Returns an empty table where
  GetProfessions is unavailable" (core.lua:4505-4508) - TBC Classic has no GetProfessions. Result:
  a known profession reads unknown -> prof_goal walks to a trainer and ends "already known (or not
  offered yet)" after the trip. Fix: expand skill headers before the walk. Regression risk: Low.

### CORE-B-11 | Low | confidence High | bags.lua:39-46 and 85; gather/engine.lua:506
* Game objects used as table keys / compared with `~=`: `set[info.object] = true`,
  `not equipped[s.item]`, `if o ~= S.node`. AGENTS.md: "compare game objects by GUID, never ==".
  If the core pushes a fresh userdata per read, equipped_set never matches. Harmless today, because
  inventory_helper:get_character_bag_slots already leaves worn gear out (IZI API inventory-helper
  doc: "This module returns backpack items only"); gather/engine only re-assigns the same node.
  Fix: key by get_guid(). Regression risk: Low.

### CORE-B-12 | INFO | conjure.lua:85
* `player:get_class_id()` is not declared anywhere in the stubs; reached only when get_class()
  (game_object.lua:115) is not a number; pcall-guarded. Unverified API, no effect normally.

### CORE-B-13 | INFO | gather/mount.lua:50-58
* `for i = 0, n do core.spell_book.get_mount_info(i)` then `core.input.mount(i)`. Neither stub
  (core.lua:4218-4223, 3639-3642) states the index base. The loop covers both bases and nil-checks,
  so it is safe, but the index handed to core.input.mount must use the same base as get_mount_info -
  verify once.

### CORE-B-14 | INFO | quest/npc.lua:350-355 (gossip_ids_are_rows)
* Treats every `get_game_version() == "Vanilla"` client as row-index gossip. The stub says only the
  private-server builds (`wow_vanilla_ps`, `wow_tbc_ps`) use row indexes (core.lua:5864-5868); on
  Blizzard Era the real ids are dropped and title / position matching is used instead.
  Conservative, not wrong.

### CORE-B-15 | INFO | quest/engine.lua:1634-1635, 2498-2500
* core.reload_game_ui is undeclared - intentional (AGENTS.md), type-checked and pcall'd.

### CORE-B-16 | INFO | AGENTS.md vs quest/guide.lua:3029-3061
* AGENTS.md says "RestedXP has no 'skip step' API"; the stub declares
  core.addons.rested_xp.skip_current_step (core.lua:7676-7684, added 2026-10-04) and guide.lua calls
  it through ns_call. The code is correct; AGENTS.md is stale.

### Checked and found correct (no finding)
* Loot: quest/engine.lua:3048-3050, loot.lua:529-531, gather/engine.lua:458-460 all loop 0..n-1 (core.lua:1452 "Every loot index below is 0 based").
* Vendor: get_vendor_item_info / buy_item 1..count (core.lua:1832-1835; cor_api_input.txt:1287 "The vendor item index (1-based)").
* Taxi: num_nodes / node_name / node_type / take_node 1..n, "INVALID" and "" handled, REACHABLE gate (core.lua:2547-2606).
* Gossip: gossip_option_id / quest_id handed straight back to the selector, never stored; positional fallback only for id 0 (core.lua:5916-5941, 5906-5908).
* Quest log: get_quest_log_title(1..n), is_header skipped, is_complete 1 / -1 handled; get_quest_log_leader_board(j, idx) argument order; abandon_quest_by_id preferred, select + set + abandon fallback.
* Rewards: get_num_quest_choices range 1..n, get_quest_reward(0) for "no choice" (core.lua:5998-6000, 6171-6175).
* Bags: get_num_bag_slots(bag + 1) paired with get_items_in_bag(bag) everywhere (core.lua:1127-1140); get_bag_inventory_slot(1..4); the equip_container_item / get_pending_equip_slot / equip_pending_item / has_cursor_item / clear_cursor flow matches core.lua:2955-3005; destroy_container_item used with helper pairs; selling only via use_container_item (never use_item).
* Durability: slots 1..19 with max > 0 checked (core.lua:1224-1228).
* Repair: can_merchant_repair read before trusting a zero cost (core.lua:1205-1214).
* Object lookup: get_object_from_guid result re-checked by GUID (loot.lua:168-172), as core.lua:3797-3825 advises.
