# FROZEN — this is the archived MasterArthasNav build

**Do not fix anything here. The live product is `products_src/restedXP_questing_sentinel`.**

Audit F8, decided 2026-10-28.

## What this tree is

| | This tree | The live tree |
|---|---|---|
| Path | `products_src/restedXP_questing` | `products_src/restedXP_questing_sentinel` |
| Branch | `dev` | `sentinel-nav` |
| Last version | 4.0.9 (2026-10-28) | 4.42.0 and counting |
| Navigation | MasterArthasNav / AmeisenNav | Sentinel Navigation v0.24 |
| Loaded by the launcher | **no** | **yes** |

Both are working trees of the same repository,
`L333T/90123-12333-44a-asd32r1f324fg-3f3fqwf-mf`. `main` is the common ancestor of
both (v4.0.8, 2026-10-24) and is the archived pre-Sentinel build that
`mfcore/catalog.lua` describes as "The main branches keep the old MasterArthasNav
builds". `dev` is `main` plus three commits; `sentinel-nav` is `main` plus
fifty-six. Nothing has ever merged back from `sentinel-nav`.

`plugin/Master_Farmer/mfcore/catalog.lua` loads RestedXP Questing from
`branch = "sentinel-nav"`, as it does every other product. **Nothing in the shipped
launcher can reach this tree or the `main` branch.**

## Why it is frozen rather than merged

The audit offered two endings: merge `sentinel-nav` into `main` and retire this tree,
or freeze it. Merging is the wrong one — `main` is a deliberate archive of the
MasterArthasNav build, and merging would overwrite the thing it exists to keep.

Freezing, on the other hand, ends a cost that was real. Every fix was being written
twice: the kite-retreat fix of 2026-10-28, then F5 (death zones) and F1
(`core.reload_game_ui`) the same day. That doubling bought nothing, because no user
can load this tree.

## What was done

- 28 tests that defaulted to this tree now default to the live one. They had been
  asserting the archive, so the live product was that much less covered than the
  suite suggested. Verified first: each produces the identical number of assertions
  against both trees.
- 9 tests stay pinned here, because they assert behaviour the Sentinel port
  deliberately replaced and so fail against the live tree by design — rays before
  the 2026-10-25 rule change, `nav_to` exact-path walks, pivot-hold steering,
  MasterArthasNav `get_all_heights`. Each now carries a header saying which and why.
  They are the archive's regression tests and belong here.
- `tests/test_restedxp_freeze.lua` keeps these facts true.

## If you need to change something

- A fix for the product users run goes to `products_src/restedXP_questing_sentinel`
  only. Do not port it here.
- This tree exists to be read, and to keep the 9 pinned tests meaningful. v4.0.9 is
  the last version it receives.
- Reviving it would mean a catalog entry pointing at `dev` or `main`, which is the
  user's decision, not a maintenance step.
