> **Evidence appendix (2026-10-11, audit of 2.305.0).** Working notes from one audit pass, kept for the per-finding evidence (stub file:line citations, symbol tables, scenarios). Statuses here are as found BEFORE any fix. The current status of every finding, and which ones were re-verified, is in `docs/CODEBASE_AUDIT_REPORT.md`.

# Audit C - IZI / unit / spell API usage (combat & rotation scope)

Repo: `C:\Users\ebene\OneDrive\Desktop\SNES_\Master_Farmer_Grindbot` (v2.305.0), read-only.
Contract: `C:\Users\ebene\OneDrive\Documents\daaa22\scripts\.api` (izi_sdk.lua, game_object.lua, core.lua, common/modules/*, common/utility/*, enums.lua).
Scope: smart.lua, spellbook.lua, spellcheck.lua, castq.lua, targeting.lua, combat.lua, auras.lua, buffs.lua, pets.lua, power.lua, racials.lua, adapt.lua, rotation.lua, rotations/*.lua, predict.lua, picks.lua, strafe.lua, professions.lua, data/class_spells.lua, data/racials.lua.

Intentional choices from AGENTS.md respected (mana via power.lua, LoS via player:los_to, no izi.is_los, Lua 5.1 shape).

## Data-condition check (data/class_spells.lua -> smart.lua `c`)

`c.*` called by class data: aoe_n, behind, buff, cp, debuff, def_pct, dist, group_up, heal_pct, hp, in_combat, mana, melee_yards, near, rage, self_debuff_id, specials (guarded by `type(c.specials)=="function"`), stealthed, tdebuff_any, thp, tmoving, ttype.
All are defined in smart.lua:517-721 (`function c.xxx`). No colon calls (`c:`) in data. Helper closures (seal_up, not_shadowform, target_frozen, rage_dump, mana_below, rage_at_least) only call defined members. **No undefined c.xxx -> no runtime error.** Conditions are invoked via `safe(def.when, c)` (smart.lua:1351), so even a future typo would only read as "condition false".

## (a) API symbol table

| symbol | library | declared? (stub file:line) | used in | params ok? | return handling ok? |
|---|---|---|---|---|---|
| izi.spell(id / ids[]) | izi | izi_sdk.lua:578-581 | smart 446,1698,2128; spellbook 539,585; racials 135; buffs 240; rotations/* make() | yes (`.` call, number or array) | yes (pcall/safe, false sentinel) |
| izi.now() | izi | izi_sdk.lua:607 (seconds) | everywhere | yes | yes (seconds) |
| izi.me() | izi | izi_sdk.lua:584 | spellbook, targeting, buffs, pets, adapt, strafe | yes | yes (nil-checked) |
| izi.enemies(r) | izi | izi_sdk.lua:592 | targeting 411, combat 204 (fallbacks) | yes | yes; INFO: may be combat-filtered like get_enemies_in_range (izi_sdk 295) - only a fallback |
| izi.enemies_if(r, pred) | izi | izi_sdk.lua:598 | targeting 907 | yes | yes; pred does its own is_valid/is_dead (stub 302 says filters are caller's job) |
| izi.on_combat_finish / on_spell_cancel / advanced_sequence | izi | 564 / 570 / 1446 | comments only in scope | n/a | n/a |
| spell:id() | izi_spell | izi_sdk.lua:351 | spellcheck 77, spellbook 455 | yes | yes |
| spell:is_learned() | izi_spell | 353 | spellbook 442 | yes | yes |
| spell:cooldown_up() | izi_spell | 365 | smart 907,1701; racials 171 | yes | yes (`== false` / `~= false`) |
| spell:cast_time() / cast_time_ms() | izi_spell | 356 / 357 (units of cast_time unstated) | smart 807-815 | yes | yes - ms preferred, `>20 => ms` heuristic for cast_time |
| spell:is_usable_while_moving() | izi_spell | 369 | smart 853,916,919 | yes | yes |
| spell:skips_gcd() | izi_spell | 368 | castq 123-125 | yes | yes |
| spell:track_buff/track_debuff(spec) | izi_spell | 377-378 | spellbook 594-598; rotations make() | yes (number[]) | returns self, ignored - ok |
| spell.minimum_range / maximum_range (fields) | izi_spell | 346-347 | smart 1026,1065,2331 | yes | yes (tonumber) |
| spell.ids (field) | izi_spell | 343 | spellbook 450 | yes | yes |
| spell:is_castable_to_unit(t, opts) | izi_spell | 386-389 | smart 862 | yes | yes (ok, reason via safe2) |
| spell:is_castable_to_position(t, pos, opts) | izi_spell | 392-396 | smart 860 | yes | yes |
| spell:cast_safe(t, msg, opts) | izi_spell | 426-430 | spellcheck 248 | yes | **partial** - meta.reason ("fast_queue_busy") dropped by callers' `safe()` (IZI-1) |
| spell:cast(t, msg, opts) | izi_spell | 413-417 ("no safety gates") | spellcheck 255 via smart 969, 2130; racials 186; buffs 241 (dead) | params yes | **no** - used as fallback after a cast_safe refusal and its `true` counted as a cast (IZI-1) |
| spell:cast_position(pos, msg, opts) | izi_spell | 496-500 | spellcheck 268 | yes | yes; INFO: use_prediction defaults true for position casts (izi_sdk 52) so izi may re-aim the predicted pos |
| unit:get_health_percentage() | izi patch | izi_sdk.lua:72 ("1..100") | smart 506; racials 94; rotations druid/paladin/priest | yes | **no** - 0..1.5 rescale (IZI-2) |
| unit:health_pct() | - | **UNDECLARED** (not in izi_sdk / game_object) | smart 506; racials 90; pets 251; rotations druid 85, paladin 58, priest 93 | n/a | tried first, falls through via pcall - UNVERIFIED API (IZI-7) |
| unit:health_current() | - | UNDECLARED | comments only | n/a | n/a |
| unit:get_health / get_max_health | native | game_object.lua:262/270 | smart, racials, pets, targeting, adapt | yes | yes |
| unit:mana_pct/mana_current/mana_max | izi patch | izi_sdk.lua:189-191 | power.lua 38-67; targeting 963-965 (dead fallback); smart 531 fallback | yes | yes per AGENTS (power.lua) |
| unit:get_power / get_max_power(type) | native | game_object.lua:275/278 | power.lua; smart 1304, 2297-2299 | yes (0 mana, 1 rage, 3 energy, cost_type) | yes |
| unit:rage_current() / power_current(t) | izi patch | izi_sdk.lua:196 / 183 | smart 539-542; rotations/warrior 81-85 (unused local) | yes | yes |
| unit:combo_points_current() | izi patch | izi_sdk.lua:256 (TBC reads type 14) | smart 573 | yes | yes |
| unit:get_combo_points_target() | native | game_object.lua:479 (returns game_object|nil) | smart 574 | yes | INFO - fallback reads a UNIT as points; type-guarded so it yields 0 (IZI-9) |
| unit:distance_to(other) | izi patch | izi_sdk.lua:318 | smart, targeting, combat, racials, hunter | yes | yes |
| unit:is_behind_unit / is_behind(unit) | izi patch | izi_sdk.lua:310-311 | smart 669-670 | yes (P behind T) | yes |
| unit:stealth_up() | izi patch | izi_sdk.lua:308 | smart 659, 2022; targeting 1240 | yes | yes (boolean typed, aura fallback) |
| unit:is_damage_immune() | izi patch | izi_sdk.lua:82 / 841 ("PvP immunity") | smart 1325 | yes | first value only - ok; INFO: documented as PvP immunity, may not report PvE evade |
| unit:time_to_die() | izi patch | izi_sdk.lua:129 (seconds) | smart 1340; adapt 432 | yes | yes |
| unit:gcd_remains() | izi patch | izi_sdk.lua:271 (units unstated) | smart 1291 | yes | treated as seconds - UNVERIFIED unit (IZI-8) |
| unit:is_casting / is_channeling_or_casting | izi patch | izi_sdk.lua:145/147 | smart, castq, strafe, pets | yes | yes |
| unit:get_active_spell_cast_end_time / get_active_channel_cast_end_time | native | game_object.lua:350/362 (units unstated) | castq 140,150 (compared to core.game_time ms) | yes | UNVERIFIED unit (INFO) |
| unit:is_rooted/is_stunned/is_sapped/is_feared(min_ms) | izi pvp | izi_sdk.lua:721/726/736/731 | racials 228-240 | yes (0 = any) | yes (first value) |
| unit:has_buff/has_debuff/has_aura(spec) | izi patch | izi_sdk.lua:88/99/110 | auras 150-219; pets 439 | yes (number[]) | yes; INFO: no caster/ownership filter (IZI-5) |
| unit:get_pet() / is_valid / is_dead / is_dead_or_ghost | native/izi | game_object 338/105/212, izi 142 | pets 221-236 | yes | yes (is_valid before use) |
| unit:get_item_at_inventory_slot(16/18) | native | game_object.lua:426 (row.object, slot 16 MH, 18 ranged) | smart 1096; targeting 971 | yes | yes (`.object`, get_item_id on object) |
| item:item_has_enchant / item_enchant_id / item_enchant_expiration | native | game_object.lua:452/464/460 | smart 1112-1114 | yes (on item object) | yes |
| unit:is_tap_denied() | native | game_object.lua:534 (returns number) | targeting 140 | yes | yes (handles number) |
| unit:get_classification() | native | game_object.lua:184 (1 elite,2 rareelite,3 boss) | targeting 365 | yes | yes |
| unit:get_creature_type() | native | game_object.lua:174 | smart 695, 2101 | yes | yes (vs enums.creature_type) |
| unit:get_attack_speed() | native | game_object.lua:320 (units unstated) | smart 1364; targeting 1203 | yes | yes (out-of-range values fall back to 2.6) |
| unit:los_to(unit) | izi patch | izi_sdk.lua:321 | targeting 772 | yes | yes |
| unit:get_target / get_guid / get_name / get_position / get_level / get_class / get_race_id / is_in_combat / is_moving / is_player / is_unit / can_attack / is_enemy_with / get_npc_id / is_mounted | native | game_object.lua (various) | all | yes | yes |
| unit:is_dummy() | izi patch | izi_sdk.lua:73 | targeting 477, 555 | yes | yes |
| core.spell_book.has_spell / is_spell_learned / is_spell_known | core | core.lua:4046/4053/4060 | spellbook, smart, pets | yes | yes |
| core.spell_book.get_spells() | core | core.lua:4036 | spellbook 531 | yes | yes (recursive walk) |
| core.spell_book.get_base_spell_id(id) | core | core.lua:4244 | spellbook 336,490,493 | yes | yes |
| core.spell_book.spell_has_attribute(id, 0, 0x40) | core | core.lua:4068 | smart 246 | yes | yes |
| core.spell_book.is_usable_spell(id) | core | core.lua:3939 (@field) | smart 261 | yes | yes |
| core.spell_book.get_spell_description(id) | core | core.lua:4016 | smart 409 | yes | yes |
| core.spell_book.get_spell_costs(id) | core | core.lua:4120 | smart 1298; adapt 418 | yes | yes (cost_type, cost, required_buff_id) |
| core.spell_book.get_spell_cooldown(id) | core | core.lua:3957 ("cooldown duration ... seconds") | spellcheck 158 | yes | INFO: "duration" may be total, not remaining - used only to confirm helper's "on cooldown" |
| core.spell_book.get_spell_base_cooldown(id) | core | core.lua:3971 (cooldown_ms, gcd_ms) | castq 127-131 | yes | yes (ms fields) |
| core.spell_book.get_spell_cast_time(id) | core | core.lua:4161 (seconds) | adapt 332 | yes | yes (>20 => ms guard) |
| core.spell_book.is_current_spell(id) | core | core.lua:4364 | smart 1363 | yes | yes |
| core.spell_book.get_shapeshift_form / _id / _info | core | core.lua:4452/4440/4475 | smart 732-741; druid 141; warrior 97 (unused) | yes | yes (form id 17/18/19, druid 1/5/8) |
| core.spell_book.get_spell_min_range / max_range | core | core.lua:4138/4145 | hunter 101-102 | yes | yes (sanity-clamped) |
| core.spell_book.get_pet_happiness() | core | core.lua:4379 (table) | pets 274 | yes | yes (Forever skipped) |
| core.spell_book.get_professions / get_profession_info | core | core.lua:4509/4529 | professions 49-54,83 | yes | yes |
| spell_helper:is_spell_castable(id,c,t,sf,sr,su,sc,sl,slos) | spell_helper | spell_helper.lua (is_spell_castable) | spellcheck 192 | yes (los at arg 9) | yes |
| spell_helper:is_spell_castable_position(id,c,t,pos,sf,sr,q,su,sc,sl,slos) | spell_helper | spell_helper.lua | spellcheck 202 | yes (los at arg 11) | yes |
| spell_helper: in_range / within_angle / in_line_of_sight(_position) / get_spell_cost / can_afford_spell / is_spell_on_cooldown / has_spell_equipped | spell_helper | spell_helper.lua | spellcheck 97-113 | yes | yes |
| spell_queue:queue_spell_target(_fast) / queue_spell_position(_fast) | spell_queue | spell_queue.lua:21-27 | castq 191-198 | yes (id, target/pos, priority, msg, allow_movement) | yes (pcall) |
| spell_queue:get_queue_snapshot / purge_by_spell / is_in_fast_queue | spell_queue | spell_queue.lua:45-49 | castq 81,224,185 | yes | yes |
| buff_manager:get_buff_data/get_debuff_data/get_aura_data(u, ids, cache_ms) | buff_manager | buff_manager.lua:39-43 (`remaining` = ms) | auras 141,171,198 | yes | **unit mismatch latent** in *_expiring (IZI-4) |
| auto_attack_helper:start_attack/stop_attack(t, type) / is_auto_attacking(u) / get_last/next_attack_core_time(u) / ATTACK_TYPE | auto_attack_helper | auto_attack_helper.lua:18-50 | smart 896; targeting 1088-1194; adapt 341,584-587 | yes | yes (core time vs core.time seconds) |
| pet_handler:set_pet_state / move_pet_to_position / on_render / pet_state | pet_handler | pet_handler.lua:10-13 | pets 151-196 | yes | yes |
| health_prediction:get_incoming_damage / speculate_damage | health_prediction | health_prediction.lua | adapt 453,575 | yes | yes |
| combat_forecast:get_forecast_single / get_min_combat_length / is_valid_forecast_logic / enum | combat_forecast | combat_forecast.lua | adapt 434,556-561 | yes | get_forecast_single returns `any` -> tonumber (UNVERIFIED shape, guarded) |
| spell_prediction:new_spell_data / get_cast_position / get_circle_list / get_cone_list | spell_prediction | spell_prediction.lua:53-72 | predict 106-131 | yes (8 args) | yes (amount_of_hits, cast_position); INFO cast_time unit unstated (passes s) |
| unit_helper:get_enemy_list_around(pos, r, oc, bl, po, dead) | unit_helper | unit_helper.lua:75 | targeting 404, 866 | yes | yes |
| core.input.* (set_target, pet_attack(target), set_pet_*, loot_item(0-based), close_loot, dismount, strafe_*/move_forward_*) | core | core.lua 3067-3661 | targeting, pets, smart, combat, strafe | yes | n/a |
| core.game_ui.get_loot_item_count | core | core.lua:1454 (0-based indices) | smart 2065-2068 (0..n-1) | yes | yes |
| core.register_on_spell_cast_callback | core | core.lua:64 (spell_id, caster, target) | adapt 609 | yes | yes |
| core.quests.get_item_info | core | core.lua quest_item_info | targeting 987,1067 | yes | yes (class_id, subclass_id, equip_loc, item_sub_type) |

## (b) Findings

### IZI-1 | MEDIUM | CONFIRMED | ungated `spell:cast` fallback after a `cast_safe` refusal; its `true` is counted as a cast
- **file:line**: smart.lua:966-970 (main rotation direct path, also reached whenever the queue path's izi check refuses: smart.lua:961), smart.lua:2129-2130 (Pick Pocket), racials.lua:183-186 (every non-"extra" racial: Escape Artist, Will of the Forsaken, Stoneform, Blood Fury, Berserking, War Stomp, Eureka!...), buffs.lua:240-242 (dead code, `buffs.tick` returns at once).
- **excerpt** (smart.lua:967-970):
  ```lua
  ok = safe(function() return spellcheck.cast_safe(sp, unit, e.name) end)
  if ok ~= true then
      ok = safe(function() return spellcheck.cast(sp, unit, e.name) end)
  end
  ```
- **actual vs expected**: izi documents `cast` as "Queues the spell with no safety gates" (izi_sdk.lua:412) and `cast_safe` as "true means it was queued" after "the full safety gates" (420); off-GCD refusals with reason `"fast_queue_busy"` must "Do not treat ... as a failed cast" (421-425). The code throws away the meta (single-value `safe`), then re-sends the same spell with zero gates (range, LoS, usable, moving, immune, cooldown other than the helper's), and treats `cast`'s `true` (= queued) as success. spellcheck's own gate only blocks a client-confirmed cooldown (spellcheck.lua:145-179), so nothing else stands in the way.
- **evidence**: izi_sdk.lua:411-430; racials.lua:177-181 already records the consequence for the "extra" spells ("izi's cast 'queues the spell with no safety gates' and answers true ... counted as cast every ACT_GAP - 106 times in one session").
- **scenario**: (1) Gnome rogue sapped/stunned: `racials.escape_tick` runs every 0.25 s; Escape Artist cannot break a stun/sap, `cast_safe` refuses, `cast` queues it and answers true -> logged "cast", `last_act` set, repeated 4x/s for the whole stun, holding the racial ACT_GAP. (2) Forever "Eureka!" (fight_start): a refused cast_safe still sets `fight.used = true` -> the once-per-fight racial is wasted for that fight. (3) Rotation: izi refuses Frostbolt because izi's own LoS/range trace says no while `movement.has_los` said yes -> ungated `cast` -> `ok == true` -> `last_gcd_cast = now`, `try` returns true, nothing else is tried that tick; the client answers "Target not in line of sight" and the same entry wins again next tick (no FAIL_GAP because it "succeeded"). (4) An off-GCD spell refused with `fast_queue_busy` gets `fail_until = now + 1.5 s` (smart.lua:1003) instead of a retry next frame.
- **fix**: capture both returns (`local ok, meta = spellcheck.cast_safe(...)`); on `meta.reason == "fast_queue_busy"` return a soft "not failed" (no fail_until); otherwise do not fall back to `spell:cast` (or only for an explicit allow-list such as the 2.252.0 Rogue melee case, and then with `skip_*` options on `cast_safe` instead of the gateless `cast`). Racials: pass `safe_only = true` for all kinds (as already done for extras), and for Escape Artist only try under a root/snare.
- **callers**: smart.try -> cast (every class rotation, pet summons, Mend Pet, Throw, Stealth, Sap); racials.tick / escape_tick / ooc; rogue_stealth Pick Pocket.
- **regression risk**: Medium. 2.252.0 deliberately added the fallback because izi refused Sinister Strike at 0.1 yd; removing it can bring that stall back for that case. Keep a narrow, logged fallback for melee strikes refused with a range/facing reason only.

### IZI-2 | MEDIUM | CONFIRMED | health % rescaled from 0..1.5 although the API returns 1..100
- **file:line**: smart.lua:498-502 (`pct`, used by `health_of` -> c.hp / c.thp), racials.lua:80-87 (`as_pct`), pets.lua:252-255, rotations/druid.lua:76-83, rotations/paladin.lua (as_pct), rotations/priest.lua (as_pct, used at 161); same pattern in targeting.lua:940-951 and power.lua:68 (last-resort mana fallbacks only).
- **excerpt**:
  ```lua
  local function pct(v)
      if type(v) ~= "number" then return nil end
      if v >= 0 and v <= 1.5 then return v * 100 end
      return v
  end
  ```
- **actual vs expected**: izi_sdk.lua:72 `get_health_percentage ... -- 1..100 (e.g., 90 means ~90% HP)`. Any real reading in (0, 1.5] (a unit at 0.1-1.5% health) is multiplied by 100 and becomes 10-150%.
- **scenario**: player at 1.2% health -> `c.hp()` = 120 -> COND.heal / COND.defensive false, racial "heal" (Gift of the Naaru) and Stoneform proxy false: no heal or defensive at the most critical moment. Mob at 1% -> `c.thp()` = 100 -> execute/finisher "dying target" branches (smart.lua:1157, 1204) skipped, COND.cooldown fires a cooldown on a mob about to die, COND.debuff applies a DoT. Pet at 1% -> Mend Pet threshold not met.
- **fix**: read `get_health_percentage()` as-is (it is 1..100); only if the undeclared `health_pct` is kept, rescale that value alone, or better derive from `get_health()/get_max_health()`.
- **callers**: smart.c.hp/thp (every class condition, COND.*), racials.wants, pets.maintain / mend_hold / hunter_pet, priest.should_retreat.
- **regression risk**: Low (a 1-char threshold change or dropping the rescale for the declared API).

### IZI-3 | MEDIUM | PROBABLE (logic, high confidence) | `pack_interrupt` swaps `T` without resetting the per-tick memo -> stale distance / health / immunity leak
- **file:line**: smart.lua:1836-1854 (with memo at 495-496, 580-585, 522-525, 1323-1329).
- **excerpt**: `T = u ... if try(bucket[k], nil) then T = keep ... end ... T = keep` - `memo.dist`, `memo.thp`, `memo.t_immune`, `memo["t"..r]` are not cleared on either swap.
- **actual vs expected**: `c.dist()`, `c.thp()`, `target_immune()` memoise against whatever `T` was when first asked. Asked first for the pack caster `u` inside `try`/`in_reach`/`dies_before`, the values stay for the real target for the rest of the tick (and vice-versa).
- **scenario**: Mage with Counterspell ticked fights mob A at 28 yd; add B casting at 8 yd. `try(Counterspell)` on B computes `memo.dist = 8`, `memo.thp = B's hp`; Counterspell is on cooldown -> fails; `T = A`. For the rest of that tick every condition sees A at 8 yd (Shaman `c.dist() > c.melee_yards()` picks the wrong bolt/shock; hunter `min = 11` dead-zone check refuses all shots; the ranged cap at smart.lua:1045 uses 8 instead of 28), and A's execute / debuff thresholds use B's health. Repeats every tick while B casts.
- **fix**: save/restore and clear `memo` (or call `begin(P, u, PACK)` / `begin(P, keep, PACK)`) around the swap.
- **callers**: smart.combat COMBAT_ORDER "interrupt" step.
- **regression risk**: Low.

### IZI-4 | LOW (latent) | CONFIRMED | `auras.*_expiring` compares buff_manager `remaining` (ms) with seconds
- **file:line**: auras.lua:246-279 (`d.remaining < secs`), shape() auras.lua:96.
- **actual vs expected**: buff_manager.lua:11/37 `remaining number -- remaining time in ms`; the API doc of `buff_expiring(unit, spec, secs)` says "less than `secs` left". A 3 s lead would compare 3000 ms < 3 -> never refreshes early.
- **scenario**: today latent - the only caller is buffs.lua:186 with `REFRESH_LEAD = 0` inside the disabled `buffs.tick`. Any future early-refresh caller (DoT/buff refresh at N s) silently never refreshes early.
- **fix**: convert in `shape()` (`remaining = (tonumber(data.remaining) or 0) / 1000`) or compare with `secs * 1000`; keep `math.huge` for the boolean fallback.
- **callers**: buffs.needs_cast (dead).
- **regression risk**: None today.

### IZI-5 | LOW | PROBABLE | aura reads ignore ownership (another player's DoT / buff counts as ours)
- **file:line**: auras.lua:163-187 (debuff), used by smart.lua:677-684 (`c.debuff`, `c.tdebuff_any`), smart.lua:1167 (COND.debuff), pets.lua:439.
- **actual vs expected**: buff_manager_data carries `caster` (buff_manager.lua:16) and izi has no "mine" filter on `has_debuff`; the code never checks it.
- **scenario**: a second Warlock's Immolate on the grind mob -> `c.debuff("Immolate")` true -> Conflagrate offered (class_spells.lua:505) and refused by the game (needs your Immolate) -> FAIL_GAP; our own Corruption/Immolate/Rend/Rupture skipped because someone else's is up. Rare while solo grinding.
- **fix**: for target debuffs, accept only `data.caster` whose GUID equals the player's (GUID compare per AGENTS), falling back to the boolean only when the module is absent.
- **regression risk**: Low-Medium (buff_manager caster may be nil on some builds - keep boolean fallback).

### IZI-6 | INFO | `unit == P` / `target == caster` object identity compares
- smart.lua:874 (`self = e.self == true or unit == P`), smart.lua:1045 (`unit == T`), spellcheck.lua:127, 189.
- Both sides are the same Lua reference in every current path (unit is literally `P`/`T`), so no wrong result found; AGENTS.md asks for GUID compares. spellcheck.gate_unit already uses GUID `same()`. Recommend `same()` in can_cast/why too.

### IZI-7 | INFO / UNVERIFIED API | `unit:health_pct()` is not declared
- smart.lua:506, racials.lua:90, pets.lua:251, rotations/druid.lua:85, paladin.lua:58, priest.lua:93. Not in izi_sdk.lua or game_object.lua. Always pcall-guarded with a declared fallback (`get_health_percentage`, then get_health/get_max_health), so harmless; it is the reason the 0..1.5 rescale (IZI-2) exists. Prefer dropping it.

### IZI-8 | INFO / UNVERIFIED unit | `gcd_remains()` read as seconds
- smart.lua:1291-1295. izi_sdk.lua:271 gives no unit. If it were ms, `g > window (0.35)` would hold to the last ms of the GCD and the queue-ahead window would never apply (no wrong cast, only lost queue-ahead). Logs (`"GCD %.1f s"`) would show values like 1500 - check one session log to settle it.

### IZI-9 | INFO | `get_combo_points_target()` used as a combo-point count fallback
- smart.lua:573-575. game_object.lua:479 returns `game_object|nil` (the unit holding the points), not a number. The `type(n) == "number"` guard turns it into 0, so it never errors; it just never helps. If `combo_points_current` ever fails, finishers only fire via the low-HP branches.

### IZI-10 | INFO | units not documented, handled defensively
- `spell:cast_time()` (izi_sdk 356, unit unstated) - smart.cast_seconds prefers cast_time_ms and applies a `>20 => ms` heuristic: ok.
- `get_attack_speed()` (game_object 320) - clamped 0..10 s else 2.6: ok.
- `get_active_spell_cast_end_time()` (game_object 350) compared to `core.game_time()` ms in castq.cast_left: unit unstated - UNVERIFIED.
- `core.spell_book.get_spell_cooldown` "cooldown duration" (core 3957) used as "is on cooldown" confirmation (spellcheck 157-161): if it is the total duration it confirms any spell with a cooldown, which only preserves the helper's own verdict - harmless.
- spell_prediction `new_spell_data(..., cast_time, ...)` given seconds (predict 106-129); izi's pos_cast_opts.cast_time is ms (izi_sdk 58) but spell_prediction does not state its unit - UNVERIFIED.
- `is_damage_immune` is documented as PvP immunity (izi_sdk 82); PvE evade may not be reported - the gate is just weaker, not wrong.
- `spellcheck.cast_position` -> `sp:cast_position(pos, ..., {min_hits=1, aoe_radius=8})`: position casts default `use_prediction = true` (izi_sdk 52), so izi may re-aim away from the MOST_HITS pos predict.lua computed; pass `use_prediction = false` if the precomputed pos must be used.

### Verified OK (no finding)
- All `core.spell_book.*` names/arity in scope match core.lua (incl. `is_usable_spell` as @field 3939, `spell_has_attribute(id, 0, 0x40)` = SPELL_ATTR0_PASSIVE).
- spell_helper argument positions in spellcheck (skip_los at arg 9 / 11) match spell_helper.lua.
- spell_queue calls (castq) match spell_queue.lua including allow_movement and fast-queue one-at-a-time handling.
- `get_spell_base_cooldown` read as ms fields; `get_spell_cast_time` seconds with ms guard; loot indices 0-based as documented.
- Stored units: pets.get, combat.alive, targeting.start_auto_attack, rotation 384 call `is_valid` before use; target/guid compares elsewhere are by GUID.
- Stance/form ids: STANCE_BY_FORM_ID 17/18/19 and druid 1/5/8 match GetShapeshiftFormID; classification 1/2/3 matches game_object.lua:176-183.
- get_item_at_inventory_slot read through `.object` (16 main hand, 18 ranged) per game_object.lua:418-426; enchant calls on the item object.
- `is_tap_denied` returns number - handled.
- Data conditions: every `c.xxx` used in data/class_spells.lua is defined in smart.lua.
- rotations/warrior.lua `stance()` / `rage()` are unused locals (no effect).
