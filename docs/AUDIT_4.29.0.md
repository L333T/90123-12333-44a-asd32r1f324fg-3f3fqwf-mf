# restedXP_questing audit - 4.29.0 (2026-10-25)

Product: `products_src/restedXP_questing_sentinel` (branch sentinel-nav), 146 Lua files.
Checked against the Sylvanas `.api` stubs (`Documents/gi2nul5hCV/4314f4cfd81e/scripts/.api`), the
generated API docs (`Desktop/Core_Api/Generated_Lua_API_Database/docs`), the Sentinel docs
(`docs/SENTINEL_API.md`, `docs/SENTINEL_V024.md`) and the project rules (`AGENTS.md`).
Every fix is tagged `-- audit 4.29.0:` in the code.

## 1. Automated pass

| Check | Result |
|---|---|
| Syntax (Lua 5.4, Lua 5.1, LuaJIT 2.1 - `make_local.py`) | 0 failed |
| Lua 5.1 limits (60 upvalues / 200 locals) | OK (LuaJIT enforces them; all files load) |
| Global writes (`luajit -bl`, GSET) | 0 |
| Undeclared global reads | 1 bug fixed (`player` in main.lua); `MASTER_FARMER` is the launcher's product env (intended) |
| `core.*` names not in the stubs | none besides the intentional `core.reload_game_ui` and `core.spell_book.is_usable_spell` (declared as a field); one hit was a comment |
| `os.*` | 2, both guarded (`type(os) == "table"`) |
| `goto` | none (the hits are the string `"goto"`, a step kind) |
| API surface list | `tests/api_surface.lua` regenerated from the current stubs |

## 2. Issues found and fixed

| # | File | Sev. | Issue | Fix |
|---|---|---|---|---|
| 1 | main.lua (update loop) | High | `og.tick(player)` read an undefined global `player` (always nil): the object-interaction lock never saw the Opening cast and could drop after 8 s | reads the local player there |
| 2 | movement/nav.lua nav_to | High | a floor query (get_all_heights) that never answered blocked walks to that spot for up to 120 s; the 10 s stale limit was never applied | a query unanswered after 10 s is stale; the walk goes out at the guessed height |
| 3 | movement/combat.lua flee / kite | High | a lost flee callback left the flee pending for ever - combat_engage returned false every tick, nothing was attacked again; a lost kite callback blocked retreats for that target | pending kite / flee requests expire after 3 s |
| 4 | quest/engine.lua IS.finish_first | High | `x and f() or nil` turned quest_ready's `false` into nil, so "turn-in not ready -> finish the objectives first" (2.319.0) never ran | explicit if, `false` kept |
| 5 | movement/nav.lua issue_walk / follow_route | Medium | a new walk never cleared the old floor-scan marker, so the "walk ended without a callback" check never ran while it stood | both clear it |
| 6 | movement/nav.lua pulse deferred stop | Medium | after 3 s the deferred stop was sent even while Sentinel still waited for its path (rule: never stop the client while its path request is in flight) | sent only once no path is pending |
| 7 | movement/sight.lua GAP | Medium | path probes every 0.15 s across enemies (~7 find_path + raycast requests/s) - against the <= 1 request/s rule | 1.0 s |
| 8 | path_runner.lua tick | Medium | waypoint waits / actions never ran: read from the bare vec3 `wp_at()` instead of the path's holds | `path_format.extras(path, index)` |
| 9 | path_format.lua encode_json | Medium | looped over `normalized.waypoints`, which normalize drops - every path save / profile seed threw | encodes from the flat coords + holds (round trip checked) |
| 10 | quest/guide.lua fightable | Medium | `is_tap_denied() ~= true` - the stub returns a number, so mobs tapped by others (1) counted as fightable for every finder | same test as targeting.tap_denied (true or non-zero) |
| 11 | quest/threat.lua | Medium | same `is_tap_denied` mistake - tapped mobs could be pulled pre-emptively | same fix |
| 12 | quest/guide.lua use_bag_item | Medium | passed the game object to `use_item` / `use_item_target`, which take an item id (stub) | item id first, the object only when no id is readable |
| 13 | quest/useitem.lua U.goal | Medium | a use_object "refused" never counted a try: an object that never accepts was retried every 0.5 s for ever | a refusal after closing in counts; TRIES -> skipped |
| 14 | targeting.lua find_mobs | Medium | cached scan units had `distance_to` called before `is_valid()` (native crash risk on a freed unit) | is_valid first |
| 15 | targeting.lua all_enemy_units | Medium | cached units had get_guid / get_position read without `is_valid()` | is_valid first |
| 16 | combat.lua combat.scan | Medium | called the non-existent `targeting.enemy_list` - fell back to izi.enemies and skipped the 4.21.0 "ignore 15+ levels below" rule for the rotation's pack | skips units `targeting.ignore_low` rejects |
| 17 | adapt.lua fight_left | Medium | the forecast's 1.1 s "no data" answer was taken as the fight length - opener DoTs (Corruption, Immolate, SW:Pain, Moonfire ...) skipped on every pull and ranked near zero | without forecast data: the learned kill time, else 10 s |
| 18 | smart.lua dagger_equipped | Medium | an empty item info (not loaded yet) was cached as "no dagger" for good - Rogues never used Backstab / Ambush / Gouge | cached only when the info answered; asked again after 2 s |
| 19 | resting.lua | Medium | resting uses items with use_item, which SELLS while a merchant window is open - arriving at a merchant below the rest line sold food / water | resting stands down while a merchant window is open |
| 20 | vendor.lua vendor.reset | Medium | a reset left supplier_guid / name / skip / inn / window_seen set - the next trip chased a stale supplier ("Vendor not found"), skipped refresh_consumables | reset clears them |
| 21 | supplies.lua carried | Medium | counted food / water with raw get_items_in_bag(0..4), which includes bank storage - restocks bought nothing (and broke the bags.list rule) | counts from bags.list |
| 22 | movement/sentinel.lua S.progress | Low | get_progress().percent is 0..1 but shown as a percent ("0 %" / "1 %") | values <= 1 scaled by 100 |
| 23 | movement.lua / geometry.lua interact | Low | a failed is_unit() call fell through to interact_with_object on an object of unknown kind (the crash call) | returns false |
| 24 | quest/threat.lua T.check | Low | the cached "attack" unit (<= 0.25 s old) was handed back without is_valid() | cache dropped when the unit is gone |
| 25 | quest/engine.lua blacklisted | Low | ipairs over `{ a or nil, b or nil }` stops at the first nil - an unreadable guid skipped the npc-id blacklist check | explicit 2-element loop |
| 26 | quest/travel.lua far_travel | Low | `trip.tried[trip.fm_guid] = true` with fm_guid nil -> "table index is nil" | guarded |
| 27 | equip.lua merchant guard | Low | only get_vendor_item_count > 0 counted as a merchant; with an empty / unreadable list use_item would sell the upgrade | also can_merchant_repair() |
| 28 | healing.lua potions | Low | combat potions through use_item with a merchant window open would be sold | no potion while a merchant window is open |
| 29 | merchants.lua rv_load | Low | route ids with spaces failed the line pattern - saved route vendors lost after a reload | pattern takes the key greedily before the six fixed fields |
| 30 | tools/gen_rxp_vendors.py -> data/rxp_vendors.lua | Low | Forever `.target Name::12345` kept `::id` in 9 vendor names (find_named, skip list and merge broke) | stripped; the id used when the .vendor line has none (172 -> 171 vendors) |
| 31 | auras.lua expiring | Low | buff_manager `remaining` is in ms, compared with seconds (early refresh could never fire) | / 1000 |
| 32 | smart.lua max_range cache | Low | keyed on the "on" count only - stale reach after tick changes | keyed on on + off counts |
| 33 | spellbook.lua watch | Low | appended to `watched` on every rebuild (grew all session) | de-duplicated |
| 34 | racials.lua for_player | Low | a new izi spell per racial on every rebuild | reused per id list |
| 35 | adapt.lua caches | Low | spec_cache grew per target per spell, never cleared; reuse kept old buckets | reset at 400 entries; weak keys |
| 36 | main.lua stopped branch | Low | the watchdog's travel / NPC timers were never reset on Stop - a restart could hearth at once | watchdog.reset() while stopped |
| 37 | gui.lua process_keybinds | Low | each key set polled twice a frame (~18 is_key_pressed) | once per frame |
| 38 | gui.lua can_start | Low | `me:get_class()` without pcall | wrapped |
| 39 | gamever.lua exact_version | Low | get_exact_game_version without pcall, re-asked on every is_forever() | guarded, read once |
| 40 | grind/zone_lookup.lua list_for | Low | a race with no zone file re-required every tick | a failed lookup is remembered |

## 3. Checked, left as is (no defect, or intentional)

- `movement/sentinel.lua` soft_replan counts success only on a `true` return (the stub documents none) - logging only.
- `movement.lua` interact (unit branch) returns the pcall result - interact_with_object only reports "sent" anyway.
- `bags.lua` equipped_set matches by object identity, not GUID - a GUID version could hide every bag item; not a proven defect.
- `vendor.lua` needs_trip re-runs the zone-merchant lookup every tick with full bags and no merchant data - returns false, does not hold the cascade.
- `loot.lua` ENTRY_TTL branch unreachable (GIVE_UP is checked first) - harmless.
- `ui.lua` log_assets_once and the Path tab Play button - unreachable (dead) code.
- `castq.lua` - dead code since the spell queue is off (2.312.0).
- `mf_skin.lua` / `mf_skin_geom.lua` - generated copies (tools/product_skin); no defects.
- Tests built on the ArthasNav mock (test_grind_handoff, test_grind_pivot, test_audit_fixes LOGIC-1) do not apply to the Sentinel branch (AGENTS.md).

## 4. To watch in game

- #4 switches on "finish the objectives before turning in" for the first time.
- #7 makes line-of-sight verdicts arrive more slowly (one Sentinel probe per second).
- #17 makes DoT classes open with their DoTs again.
