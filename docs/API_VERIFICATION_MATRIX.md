# API Verification Matrix

This matrix covers the important integrations, checked against the `.api` stubs. The stubs are identical in `daaa22`, `664322289a264b` and `ebe5e7d15a44b2aa650e7e27`.

- The full symbol-by-symbol tables, about 250 symbols with stub line numbers, are in:
  - [`audit/A_core_movement.md`](audit/A_core_movement.md) §(a)
  - [`audit/B_core_quest.md`](audit/B_core_quest.md) §(a)
  - [`audit/C_izi_combat.md`](audit/C_izi_combat.md) §(a)
- "Verified" means the name, the call style (`.` or `:`), the parameter order and types, and the return handling all match the stub declaration and its doc comment.
- Runtime behaviour beyond the stub text was **not** verifiable, because the library implementations are not on disk.

| API / Function | Library | Source of evidence | Usage verified | Parameters verified | Return handling verified | Status |
|---|---|---|---|---|---|---|
| `get_health_percentage` | izi (game_object patch) | izi_sdk.lua:72 "1..100" | yes | yes | **was wrong** (×100 rescale) | Fixed 2.306.0 |
| `get_health` / `get_max_health` | game_object | game_object.lua:262/270 | yes | yes | yes | Verified |
| `health_pct`, `get_health_percent` | none | not declared | n/a | n/a | n/a | No longer read (2.306.0) |
| `max_health` | izi | izi_sdk.lua:283 | yes | yes | yes | Verified |
| `mana_pct` | izi | izi_sdk.lua:191 (no range stated) | yes | yes | scale unstated (fallback only) | Partially verified |
| `core.get_height_for_position` | core | core.lua:480-490 "0 on a miss" | yes | yes | **was wrong** in util.lua | Fixed 2.306.0 |
| `izi.get_terrain_height` | izi | izi_sdk.lua:1282 | yes | yes | 0 treated as no answer | Fixed 2.306.0 |
| `core.get_map_id` | core | core.lua:366-368 ("current map"); logs show the zone UiMapID | yes | yes | was used as a continent id | Fixed (sentinel_adv) |
| `core.get_instance_id` | core | core.lua:372-376 (open world = continent) | yes | yes | 0 = no answer | Verified |
| `core.get_server_time` | core | core.lua:340-350 | yes | yes | 0 = no answer | Verified |
| `core.input.jump` / `ascend_stop` | core | core.lua:3606-3622 | yes | yes | paired since 2.306.0 | Fixed |
| `core.input.descend_start/stop` (sit) | core | core.lua:3624-3636 | yes | yes | n/a | Verified |
| `core.input.use_object` | core | core.lua:3359-3365 | yes | yes | boolean read | Verified (never on spell-focus objects, 2.299.0) |
| `core.input.use_item(id)` | core | core.lua | for use: yes; for equipping: **unverified** | yes | n/a | API Verification Required (#4) |
| `core.input.use_container_item(bag, slot)` | core | core.lua:2900 + inventory notes | yes | slot numbering **contradictory** | n/a | Blocked (#1) |
| `core.input.loot_item(i)` | core | core.lua (0-based) | yes | yes (0..n-1) | n/a | Verified |
| `core.quests.*` (gossip, quest log, rewards, trainer services) | core | core.lua 6000-6300 | yes | yes (index bases checked) | window state inferred from counts | Verified; window state blocked (#2) |
| `core.game_ui.get_corpse_position` | core | core.lua:1810 + user-supplied doc (zero vector = no corpse; z approximate) | yes | yes | yes (2.304.0/2.305.0) | Verified |
| `core.game_ui.get_current_map_id` | core | core.lua:1762, value undocumented | yes | yes | meaning unstated | API Verification Required (#3) |
| `core.spell_book.*` (get_shapeshift_form, _info, _id, is_usable_spell, get_spell_costs, is_current_spell…) | core | core.lua 3939-4490 | yes | yes | yes (form ids 17/18/19) | Verified |
| `core.spell_book.spell_has_attribute` | core | core.lua:4068 | yes | yes | answers false on Forever (passives) | Verified; name-based passive filter added 2.303.0 |
| `izi.spell(id)` spell object (`cast_safe`, `cast`, `cooldown_up`…) | izi | izi_sdk.lua spell section | yes | yes | `cast` true = queued, counted as cast | IZI-1 open (deferred) |
| `izi.on_combat_start/finish`, `on_spell_success` | izi | izi_sdk.lua:559-570 (return unsubscribe) | yes | yes | **unsubscribe was dropped** | Fixed 2.306.0 |
| `izi.now` / `core.time` | izi / core | both seconds since session start (audit E) | yes | n/a | mixed only in fallbacks | Verified |
| `gcd_remains` | game_object | declared; unit undocumented | yes | yes | read as seconds | API Verification Required (#5, behaviour consistent with logs) |
| `ts_override_helper` session (`create_session`, `set_pull_allowed`, `tick`, `destroy`) | common/utility | ts_override_helper.lua:12-24, 139-144 | yes | yes | TTL 500 ms was not respected | Fixed 2.306.0 |
| `buff_manager` `remaining` | common/modules | buff_manager.lua:11 (ms) | yes | yes | compared with seconds (latent) | IZI-4 open |
| `auto_attack_helper` (start, stop, is_auto_attacking, last attack time) | common/utility | auto_attack_helper.lua | yes | yes | yes | Verified |
| `unit_helper:get_enemy_list_around` | common/utility | unit_helper.lua | yes | yes | yes | Verified |
| `core.create_data_file` / `write_data_file` / `read_data_file` | core | core.lua:664-749 (write APPENDS; create returns a boolean) | yes | yes | create result unchecked | CORE-A-8 open (Low) |
| `core.reload_game_ui` | none | **not declared** | intentional (AGENTS.md), type-guarded | n/a | n/a | Known exception |
| `player:get_class_id` | none | not declared | guarded fallback only | n/a | n/a | Known exception |
| `core.addons.rested_xp.*` | core | core.lua addon section (`skip_current_step` :7682) | yes | yes | yes (incl. `skip_current_step`) | Verified |
| AmeisenNav client | own plugin | `ameisen/AmeisenNav` source and docs/API.md | yes (own code) | yes | yes | Outside the Sylvanas stubs |
