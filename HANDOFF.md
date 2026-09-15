# WheresEris — handoff

Paused 2026-09-15 to get the other mods launched. This is everything a fresh
session needs to pick it up without re-deriving a day's work. Read this before
`DESIGN.md`; DESIGN.md has the reasoning, this has the state.

## Where it stands, in one paragraph

The **logic is done and proven** across six playtests: takeoffs place a marker
on one of the spots the game itself would pick, the game lands her exactly
there, the marker clears on touchdown, nothing flickers, both of her flights
(slow `ErisFlyUp` and fast `ErisRelocate_Up`) are tracked, and the strike
marker substituted correctly the one time she used the move. **The colors are
not done.** The outline and the ground glow render in whatever color you set.
Anything attached to a *spawn point* renders red no matter what — and that
one fact, isolated over five fights, is the whole remaining problem.

## What is proven (do not re-investigate)

Each of these was established by a playtest log, not by reading code.

| Claim | Evidence |
|---|---|
| Landing marker predicts the exact spot | 6/6 `landing: teleporting to marked spot X` matching `takeoff: ... spot X`, several fights |
| Marker clears on landing, never redirects a later teleport | no `marker was stale` on a non-flight teleport since fix; `teleport (not a marked landing)` lines are correct |
| No post-landing flicker | no `landing marker moved` after a `landing:` line since the watcher retires on commit |
| Fast flight tracked | `takeoff:` lines during `ErisRelocate_Up` phases |
| Strike marker logic works | `strike windup: marker at spot 744618` → `strike: teleporting to marked spot 744618 (vanilla would have picked 792648)` |
| Outline honors its color | set Cyan, saw cyan (Rivals) |
| Ground glow (attached to **Eris**) honors its color | set Green, saw green, same fight |
| Landing marker (attached to a **spawn point**) does NOT | set White, saw red — as the glow AND as the portrait |
| It is not the art | portrait (known to render) was red under a White tint |
| It is not the render group | red in `FX_Terrain` and in `FX_Terrain_Add` |
| It is not the material | red with and without `Material = "Unlit"` |
| It is not the tint pipeline | palette resolves, no `unknown color` warning, other paths honor it |
| It is not the base map | `N_Boss01.map_text` ambient is blue, `0.59/0.68/0.96`; the red is dynamic |
| It is not a scene-wide grade | two render paths showed their colors in the same fight |

The **only variable that correlates with red is `DestinationId` being a spawn
point obstacle** rather than a unit.

## What was tried and is now known wrong (do not retry)

* **InheritFrom across SJSON files.** Resolves in file load order; the parent
  did not exist yet. Engine logged `AnimationData.cpp:218 ... does not exist`.
  The entry must be self-contained. (MODDING_HADES2.md §4 has the rule.)
* **Reusing `ApolloGroundGlow` by name for the landing marker.** Rendered red
  alongside the red ground marker. Attributed at the time to one-tint-per-name;
  now more likely the spawn-point cause below. Own name is still right.
* **Moving to plain `FX_Terrain` to escape additive washing.** Still red, and
  probably drew under the arena's lava. Back on `FX_Terrain_Add`.
* **A brighter/whiter color.** Irrelevant; the tint never reaches the sprite.
* **Testing only in Rivals.** Every color test was the "Visage of Eris" fight.
  Normal mode has never been checked for color. Do that first.

## The one hypothesis worth the next attempt

**The spawn point owner is red, and an attached animation inherits its
owner's tint.** Units are untinted so the ground glow shows its color; the
landing spots are `EnemyPointSupport` obstacles in a red-lit boss arena and
may carry a red `Color`/tint of their own, or receive one from the Rivals
presentation.

Two ways to test it, cheapest first:

1. **Read the spawn points out of the map.** They are in the binary, not the
   text file: `HadesMapper dc -s -i N_Boss01` (recipe in MODDING_HADES2.md
   §5d). Look up the IDs the log names — `744607 744608 744609 744610 744615
   744616 744617 744618 792645 792648` — and check for `Color`, `Tint`, or an
   attribute set that differs from an ordinary obstacle.
2. **Stop attaching to the spawn point.** Spawn a neutral proxy at the spot
   and attach the marker to that. Vanilla does exactly this three lines below
   the teleport pick, `EnemyAILogic.lua` `HandleEnemyTeleportation`:
   ```lua
   targetPointId = SpawnObstacle({ Name = "InvisibleTarget", DestinationId = targetPointId, ForceToValidLocation = true })
   ```
   Attach to the returned id; `Destroy` it when the marker clears. This works
   whether the cause is the map, the fight, or the engine, which is why it is
   the fix to try even if step 1 finds nothing.

If the proxy renders white, the marker is done and the strike marker gets the
same treatment for free (it shares `attachMarkerAt`).

## State of the code

* Repo `Plugin Work\Adicon-WheresEris`, junctioned into the profile, **1.0.0
  on file, unreleased**, all work committed, pushed through `9ff7ef9`; the
  strike marker and later are local only.
* **162 tests** on lua and luajit. Sections 11, 18, 19, 20 cover the marker
  lifecycle, style system, unlit/commit fixes, and strike marker. Every fix
  since the 9th is sabotage-verified; DESIGN.md's sections say which test
  catches which reversion.
* The harness records `weapon` events alongside `create` events so ordering is
  testable (20.8b). Its `base()` cannot yield, so timing bugs need that.

## Settings, and the live config

Live `.cfg` was left with the values Caleb confirmed *do* render, plus
defaults elsewhere:

```
OutlineColor        = Cyan      confirmed
GroundFxColor       = Green     confirmed
LandingMarkerStyle  = Glow      (diagnostic used Portrait; restored)
LandingMarkerColor  = White     renders red -- the open problem
StrikeMarker        = false     (diagnostic had it on; restored)
```

`LandingMarkerScale` is a multiplier on the style's base (Glow 6.0 = twice
her footprint, Portrait 0.67). Config beats code default — change both, or
it did not change. That trap cost six days once on this mod (DESIGN.md).

## Before release, regardless of the color outcome

* **CHANGELOG** has a day of churn under `[Unreleased]` — several entries
  describe intermediate states that never shipped (cyan, then white; plain
  group, then additive). Collapse to what 1.0.0 actually does.
* **README** settings table is current; the How-it-works and credits are
  from the 9th and fine.
* **Normal-mode fight** for both color and general behavior; only Rivals has
  been played.
* **`StrikeMarker`** visual never seen — she used the move in one fight, and
  it fired before the diagnostic config went in. Needs one sighting.
* **Decide the color default** once it renders: White washes on additive; a
  saturated color is the safer default. Green is proven on that floor.

## Files worth reading, in order

1. This.
2. `DESIGN.md` — every decision and every wrong turn, with the log lines.
3. `src/main.lua` header, then `registerLandingArt`, `attachMarkerAt`,
   `CONFIG.onFlyUp / onFlyDown / onStrikeWindup`, and the `SelectSpawnPoint`
   wrap.
4. `test/run_tests.lua` sections 11, 18–20.
