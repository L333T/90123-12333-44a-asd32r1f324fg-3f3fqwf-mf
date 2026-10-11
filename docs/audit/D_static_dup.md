> **Evidence appendix (2026-10-11, audit of 2.305.0).** Working notes from one audit pass, kept for the per-finding evidence (stub file:line citations, symbol tables, scenarios). Statuses here are as found BEFORE any fix. The current status of every finding, and which ones were re-verified, is in `docs/CODEBASE_AUDIT_REPORT.md`.

# D — Static analysis + duplication audit

Repo: `C:\Users\ebene\OneDrive\Desktop\SNES_\Master_Farmer_Grindbot` @ `0b18c88e` (v2.305.0), read-only.
Scope: 146 manifest files; 110 code files (manifest minus `grind/paths/**` and `data/rxp_targets.lua`) for the global scan;
`ameisen/AmeisenNav/**` (15 files) added for the duplicate and arity checks only.

Tools / scripts (all in `scratchpad\audit\`):
- `bcscan.lua` — LuaJIT `jit.util` walk of every prototype: GGET/GSET with source line, per-function upvalue count -> `bc.tsv`, `funcs_all.tsv`
- `lp.py` — luaparser top-level local count per file -> `toplocals.txt`
- `redecl.py` — top-level local redeclarations (none found)
- `dupfiles.py`, `xdup.py` — LF-normalised byte-identical groups, same-basename similarity, cross-file shared-line overlap
- `helpers.py` — every `local function X` / `local X = function` body, grouped by normalised body -> `helpers.txt`, `defs.json`
- `arity.py` — scope-aware check: every call to a local function by name that passes more arguments than it declares (no vararg) -> `arity.txt` / `arity_all.json`
- `idx.py` — calls of fixed-arity `safe`/`call` whose argument is a bare `obj.method` (method called without self) -> `idx.txt`

---

## 1. Syntax (`luajit -bl`)

All 146 manifest files compile. Also compile: `ameisen/AmeisenNav/**`, `plugin_loader/*.lua`, `.bak_pre_movement2/**`, `movement.lua.pre_rewrite.bak`.

| ID | Sev | Conf | File | Evidence | Fix | Regression risk |
|---|---|---|---|---|---|---|
| LUA-1 | Low | High | `movement.lua.monolith.bak:890` | `main function has more than 200 local variables` (not shipped: gitignored `*.bak`, not in manifest) | Delete the stale backup or move it out of the repo tree | None (not loaded) |

## 2. Globals

**GSET (global writes): 0** in all 110 code files. The only global writes are explicit `_G.MasterFarmer_Grindbot = _G.MasterFarmer_Grindbot or {}` (adapt.lua:596, callbacks.lua:105, events.lua:263, gui.lua:1734, header.lua:74, main.lua:110) — intentional shared namespace.

GGET names seen (count): type 2372, pcall 1093, require 723, core 710, tostring 598, string 304, math 292, tonumber 281, table 80, pairs 58, package 32, _G 26, rawget 18, select 15, next 15, ipairs 10, collectgarbage 7, setmetatable 4, rawset 4, MASTER_FARMER 4, os 2, xpcall 1, unpack 1, **hop 1**.
`menu` is never read as a global (gui.lua:99 declares `local menu = ui.new(...)`). `MASTER_FARMER` (gui.lua:1727-1728, ui.lua:649) is the launcher-injected table and is type-checked before use. `_G` reads are all `rawget(_G, "AmeisenNav"|"core"|"debug"|"GetWeaponEnchantInfo")` or the namespace line above.

| ID | Sev | Conf | File:line | Evidence | Fix | Regression risk |
|---|---|---|---|---|---|---|
| LUA-2 | Low | High | `quest/engine.lua:614` (in `walk_to`, line 545) | `if hop then approach = nil end` — `hop` is not declared anywhere in the file (GGET "hop"). It was the local removed in 2.266.0 (`89a7f429` "remove the recorded inn / flight-path roads"). Always nil, so the branch is dead; under a strict-globals metatable it would throw. | Delete line 614 (and the stale comment at 611-612). | None — branch can never run today. |
| LUA-3 | Medium | Medium | `deathzones.lua:80`, `spellcheck.lua:40` | `pcall(os.time)` and `return os.clock()`. The core API doc (`Sylvanas_coreAPI_IZI_API/docs-project-sylvanas-net-dev-api-core.txt` ~l.351) says *os.date() and os.time() are not available in the sandbox*. If the `os` table itself is absent, `os.time` is indexed **outside** the pcall -> `wall()` throws, which aborts `save()`/`load()` of death zones (callers at deathzones.lua:115, 138). spellcheck's `os.clock()` is a last-resort fallback (only after izi.now and core.game_time both fail). | `local os_t = rawget(_G, "os"); local f = type(os_t)=="table" and os_t.time; if type(f)=="function" then ... end`, or use `core.get_local_time` per the doc; spellcheck: `return (safe(core.time) or 0)` instead of `os.clock()`. | Low; wall() already tolerates nil. |
| LUA-4 | Info | High | `errorlog.lua:39` | `local unpack = table.unpack or unpack` reads the global on its own declaration line — intentional, correct. | none | — |

## 3. Limits (LuaJIT/5.1: 60 upvalues per function, 200 locals per function incl. main chunk)

Top-level locals per file (luaparser; counts `local` targets + `local function` in the chunk body):

| File | top-level locals |
|---|---|
| quest/engine.lua | **200** |
| smart.lua | 158 |
| quest/guide.lua | 118 |
| gui.lua | 114 |
| movement/sentinel.lua | 112 |
| vendor.lua | 111 |
| movement/terrain.lua | 92 |

Highest upvalue counts (jit.util `funcinfo().upvalues`):

| Function | upvalues |
|---|---|
| quest/engine.lua:3567 `tick_inner = function(player)` | **56** |
| movement/combat.lua:422 `C.combat_engage` | 51 |
| quest/engine.lua:1763 `dialog_goal` | 48 |
| resting.lua:796 `resting_mod.tick` | 45 |
| vendor.lua:1380 | 43 |
| trainer.lua:593 | 41 |

| ID | Sev | Conf | File:line | Evidence | Fix | Regression risk |
|---|---|---|---|---|---|---|
| LUA-5 | **High** | High | `quest/engine.lua` (main chunk) | Exactly 200 top-level locals. Verified: a copy with one extra `local __probe_extra = 1` before `return quest` fails `luajit -bl` with `qe_probe.lua:3866: main function has more than 200 local variables`. The next change that adds a top-level local breaks the quest pack (loader logs "quest pack failed" and Quest mode is gone). No top-level redeclarations to reclaim. | Move groups of state/constants into tables (e.g. `local S = { last_walk_x=..., ... }`, `local K = { TALK_SEARCH_FAR=..., ... }`), or split helpers into a `quest/engine_util.lua` module (add to manifest). Target <= 170. | Medium: mechanical but touches many references; run the quest pack in game after. |
| LUA-6 | Medium | High | `quest/engine.lua:3567` `tick_inner` | 56 upvalues (limit 60, project flag at >55). Four more captured locals and the file stops compiling. | Same refactor as LUA-5 (table-grouped state reduces upvalues too); or split tick_inner into phase functions. | Medium |
| LUA-7 | Low | High | `movement/combat.lua:422` `C.combat_engage` | 51 upvalues — headroom 9. | Watch; group constants into a table when next edited. | Low |

## 4. Shadowing / use-before-define

Method: any name read as GGET in a file that also declares that name as a local (anywhere) = a function compiled above the `local` line reading a global instead. Result: only `errorlog.lua:39 unpack` (intentional, LUA-4). No top-level redeclared locals in any file (`redecl.py`). `hop` (LUA-2) is a removed local, not a forward reference.

| ID | Sev | Conf | File:line | Evidence | Fix | Regression risk |
|---|---|---|---|---|---|---|
| LUA-8 | Low | High | `quest/engine.lua:182` | `local function debug(fmt, ...)` shadows the `debug` library for the rest of the file. No `debug.<x>` use in the file today, so harmless; a future `debug.traceback` there would call the logger. | Rename to `qdebug`. | Low (rename within one file) |

## 5. Duplicates

### 5a. Files

No byte-identical (LF-normalised) files anywhere in the repo, including `grind/paths/**`.

| ID | Sev | Conf | File(s) | Evidence | Fix | Regression risk |
|---|---|---|---|---|---|---|
| DUP-1 | Low | High | `.bak_pre_movement2/` (13 files), `movement.lua.monolith.bak` (2317 L), `movement.lua.pre_rewrite.bak` (1543 L) | Gitignored local backups of old code. Similarity to live files: path_runner 0.86, death 0.62, gui 0.50, grind/engine 0.50; monolith vs pre_rewrite 0.48 (83% shared lines). Not in manifest, not required by any code (no `require` / `package.loaded` string references them). Risk is only a person/agent editing the wrong copy; `.gitignore` comment states that risk. | Move them out of the repo folder (e.g. `SNES_\Master Farmer Versions\`). | None |
| DUP-2 | Low | High | `ameisen.zip` (repo root, untracked, 53,873 B, 2026-10-05) | Stale snapshot of `ameisen/`: 11 of 17 files differ from the current tree (`avoid, client, config, context, follow, follower, query, ui, header, main, README`), and it lacks `coords.lua`, `horizon.lua`, `pathcheck.lua`. Only `log.lua`, `transport.lua` and the 3 server files match. | Delete or move out; add `*.zip` to .gitignore (plugin_loader.zip is already handled by skip-worktree). | None |
| DUP-3 | Medium | Medium | installed `…\3cf70445e7\scripts\AmeisenNav\` vs repo `ameisen/AmeisenNav/` | Installed header says `version = "1.6.3"`, repo says `1.6.8`; 11 files differ, `anav/coords.lua` not installed. (Install path per AGENTS.md; it may not be the current install.) The bot depends on `_G.AmeisenNav` behaviour, so in-game tests may run old nav code. | Re-copy `ameisen/AmeisenNav` to the active install. | Low |
| DUP-4 | Info | High | `header.lua` / `plugin_loader/header.lua` / `ameisen/AmeisenNav/header.lua`; `grind/zones/troll.lua` / `undead.lua` | Shared boilerplate (same `call(fn, ...)` helper) and shared data-table structure only; contents differ. Not a defect. | none | — |

### 5b. Helper functions defined in many files

Counts from `helpers.txt` (names defined in >= 4 files; whitespace/comments normalised):

| Helper | defs | distinct bodies | Behaviour difference |
|---|---|---|---|
| `safe` | 49 files | 5 | V1/V2/V3/V5 (45 files) are the same `safe(fn)` = `pcall(fn)`, first result, **extra args dropped**; only the local name of the result differs (`result`/`v`/`res`/`r`). V4 `safe(fn, ...)` = `pcall(fn, ...)` **passes args**: adapt.lua:59, callbacks.lua:40, smart.lua:81, quest/mismatch.lua:59. |
| `now` | 17 | 10 | Different fallbacks: izi.now; izi.now -> core.time (s); izi.now -> core.game_time()/1000; -> 0; -> os.clock (spellcheck). Units agree (seconds) per the API doc (core.time = seconds, game_time = ms /1000). |
| `trail` | 13 | 12 | Only the tag differs in 10 of them (all pcall errorlog.trail). Differences: targeting.lua:1154 takes `(cat, fmt, ...)`; quest/engine.lua:168 `(tag, fmt, ...)` and quest/npc.lua:317 call `errorlog.trail` **without pcall** (errorlog.trail itself pcalls string.format, so low risk). |
| `call` | 7 | 3 | V1 `call(fn, a, b)` (combat.lua:105, death.lua:73, targeting.lua:69, quest/guide.lua:119) passes **at most 2 args**; header.lua:27 / ameisen header `call(fn, ...)` returns `ok, result`; quest/api_examples.lua:21 `call(fn, ...)` returns result. |
| `indexable` | 4 | 1 | identical (combat, death, targeting, quest/guide) |
| `xprobe` | 4 | 1 | identical (rotation, smart, grind/engine, movement/fsm) |
| `make` | 4 | 1 | identical (rotations druid/mage/priest/shaman) |
| `as_pct` | 4 | 2 | same logic (rotations druid/paladin/priest, racials) |
| `health_pct` | 6 | 3 | rotations druid/paladin/priest vs healing/resting vs racials; minor fallback differences |
| `guid_of`, `num`, `learned`, `finish`, `add` | 4-5 | all different | same name, unrelated behaviour (not duplicates) |

**Extra-argument call sites (the high-value check).** `arity.py` resolves every call `name(...)` to the local binding in scope (handles nested functions, shadowing, `local f = function`, reassignment) and flags calls passing more arguments than the definition declares, or ending in a multi-value expression (call/`...`) beyond the parameter count, for every non-vararg local function in all 110 code files + 15 AmeisenNav files.

**Result: 0 call sites.** Sanity checks: the walker records 24 `safe` calls in loot.lua (25 textual matches incl. the definition), 20 `call` calls in combat.lua (matches the 20 real non-comment uses), 167 `safe` calls in quest/engine.lua (168 textual incl. definition). Every `call(fn, a, b)` site passes <= 3 args. The bug pattern `safe(Tr.height, x, y, z)` was fixed in 2.300.0/2.301.0 (`cbbc37d8`, `515d3cfc`); current Tr.height uses are `pcall(Tr.height, ...)` (movement/sentinel.lua:1376, quest/engine.lua:3352) or direct calls (movement/sentinel.lua:223).

Related check — fixed-arity `safe(obj.method)` with no self (`idx.py`): only `safe(g.options)` gossip.lua:102, `safe(guide.describe)` main.lua:825, `safe(p.get)` settings.lua:173, `safe(movement.owner)`/`safe(movement.state)` quest/engine.lua:3397, plus `izi.now` / `core.time`. All are module functions (dot-call), not methods — no evidence of a bug.

| ID | Sev | Conf | File:line | Evidence | Fix | Regression risk |
|---|---|---|---|---|---|---|
| DUP-5 | Medium | High | 45 files with `safe(fn)` vs 4 with `safe(fn, ...)` (list above) | Two incompatible contracts under one name; caused the real 2.300.0 bug. No current mis-call (0 sites), but nothing prevents a recurrence. | Make every `safe` the vararg form `local function safe(fn, ...) local ok, r = pcall(fn, ...) if ok then return r end return nil end` (pure superset: identical behaviour for every existing 1-arg call), or move it to one shared module. Optionally keep `arity.py` as a pre-commit check in make_local.py. | Very low — superset semantics. |
| DUP-6 | Low | High | `call(fn, a, b)` in combat.lua:105, death.lua:73, targeting.lua:69, quest/guide.lua:119 | Silently drops a 3rd+ argument; same hazard class as DUP-5. 0 current offenders. | `local function call(fn, ...) local ok, r = pcall(fn, ...) ...` | Very low |
| DUP-7 | Low | Medium | `trail` in quest/engine.lua:168, quest/npc.lua:317 | Not wrapped in pcall unlike the other 10 trails; a throw inside errorlog's `write` would propagate into the quest tick. | `pcall(errorlog.trail, tag, fmt, ...)` | Very low |

## 6. Dead / unreferenced files

Method: every manifest module name searched as a quoted string (`"x"`) across all code + plugin_loader (covers `require("x")`, `pcall(require, "x")`, `package.loaded["x"]`, loader pack lists, `mod("x")`); string-built requires checked by hand (`"grind/zones/" .. key` in grind/zone_lookup.lua:46, `pcall(require, mod)` in grind/catalog.lua:21 / path_format.lua:232 for path packs). Every literal require that is not in the manifest is a framework `common/...` module (19 names) — no missing module. All 35 `grind/paths/ally160/*` files are named in `grind/paths/ally160/catalog.lua`.

Unreferenced manifest modules: `header` (framework entry point — expected), `grind/zones/{gnome,human,troll,undead}` (reached via the string-built require — live), and:

| ID | Sev | Conf | File | Evidence | Fix | Regression risk |
|---|---|---|---|---|---|---|
| DUP-8 | Low | High | `quest/api_examples.lua` (manifest line 140, 19,430 B) | Never required or loaded by any file; only mentioned in comments (quest/guide.lua, quest/npc.lua) and VERSIONING.md as a reference. The loader downloads it every session. Its header calls it "the call list those modules need". | Drop it from the manifest (exclude in make_manifest.py) and keep it as a doc/reference file, or move under `docs/`. | None at runtime (nothing requires it). |

Files in the repo outside the manifest and not required by the bot: `plugin_loader/*.lua` (separate loader plugin, expected), `ameisen/**` (separate plugin, expected), `.bak_pre_movement2/**`, `movement.lua.*.bak` (DUP-1), `ameisen.zip` (DUP-2).

---

### Totals
- Syntax failures: 0 shipped (1 in a gitignored backup).
- Global writes: 0. Unexpected global reads: 1 (`hop`) + `os` x2 (sandbox-availability concern).
- Limit hazards: 1 file at 200/200 locals (High), 1 function at 56/60 upvalues.
- Use-before-define: 0 real.
- Helper duplicates: `safe` x49 (2 contracts), `now` x17 (10 variants), `trail` x13 (12), `call` x7 (3). Extra-argument call sites into arg-dropping helpers: **0**.
- Dead shipped file: 1 (`quest/api_examples.lua`).
