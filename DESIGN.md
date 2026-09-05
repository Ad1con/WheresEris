# DESIGN.md

Extended rationale for WheresEris. Repo-only, not packaged -- see
`thunderstore.toml`'s `[[build.copy]]` list, which names only `CHANGELOG.md`,
`LICENSE` and `src/`. The authoritative build specification is
`WHERES_ERIS_SPEC.md`, one level up in `Plugin Work/`, not part of this
repository. This file exists for anything that spec did not need to say but a
future reader of this code will want to know.

## The one thing this mod cannot verify offline, and needs Caleb's playtest for

The landing marker's art is the game's own keepsake face for Eris
(`GUI\Screens\AwardMenu\KeepsakeMaxGift\KeepsakeMaxGift_big\Eris`, inside
`GUI.pkg`), registered as a new Animation entry via `sjson.hook` on
`Game/Animations/GUI_Screens_VFX.sjson` and attached in the 3D world with
`CreateAnimation`, the same way RealHecate attaches `ApolloGroundGlow`.

The registration technique itself is confirmed: Adicon-SelectFirstBoon
(published, 4.32.0) registers new Animation entries the same way -- FilePath
naming an existing shipped texture, `EndFrame`/`NumFrames`/`StartFrame` = 1,
`Material = "Unlit"` for a single static frame -- and it works. What is NOT
independently confirmed is attaching one of those entries with
`CreateAnimation` in the 3D world rather than `CreateScreenComponent` on a 2D
screen. SelectFirstBoon's registered entries are all consumed by
`CreateScreenComponent`; no mod on this machine has attached a GUI-atlas
texture as a world sprite before this one. Both functions almost certainly
resolve `Name` through the same underlying `Animations` table, which is why
this is the design that was built rather than inventing a new one, but
"almost certainly" is not "confirmed," and this is exactly the shape of gap
MODDING_HADES2.md section 3 rule 6 describes: the offline suite proves the
LOGIC (which spot, when, whether it moves) exhaustively; it cannot see
whether a texture renders. RealHecate's own history is the precedent --
its marker not appearing at all was invisible to any offline test and cost
roughly fifteen playtest cycles to run down, and that was for an animation
technique that WAS already confirmed working elsewhere in that mod.

If the marker does not render: the wiring underneath it (which spot, correct
eligibility, correct freeze-on-descent, correct RNG parity) is still doing its
job and is fully covered by the suite. The fix at that point is almost
certainly a different `CreateAnimation` argument (a `Group`, matching
RealHecate's own header warning about `FX_Terrain` silently filing an
animation into a render group that never draws) or a different Animations
file to hook, not a rewrite of the selection logic.

## Why BossDifficultyActive is a test flag, not a ported function

`test/harness.lua` ports `SelectSpawnPoint` and `IsSpawnPointEligible`
verbatim, per MODDING_HADES2.md section 3 rule 5 -- this mod's own correctness
depends on matching their exact behavior. It does NOT port
`IsBossDifficultyShrineUpgradeActive` (`ShrineLogic.lua:939`), which resolves
the Oath/Vow shrine's active-or-not question through
`CurrentRun.EnteredBiomes`, `GameState.ShrineUpgrades` and a Dream-run biome
map. This mod's own logic does not reimplement that decision; it asks the
real game function for the answer (via `IsGameStateEligible(enemy,
{NamedRequirements={"BossDifficultyActive"}})`, the same call
`GetWeaponAIData`'s own `ConditionalData` resolution uses,
`EnemyAILogic.lua:5956-5961`) and only routes on the result: EnemyPointSupport
under Oath, the whole map otherwise. Porting the shrine bookkeeping would
mean carrying and maintaining logic this mod's correctness does not depend
on -- the AlwaysChaosGates precedent for not porting the whole
`IsGameStateEligible` interpreter, one level further in.

## Why the wrap always calls `base()` first, unconditionally

This is section 6.2 of the spec, and it is the one rule in this mod that must
never be "optimized." `SelectSpawnPoint` shuffles with `FYShuffle`, which
draws from the run's own seeded RNG. Calling it only when needed -- say,
skipping the real call when this mod already knows its own answer -- would
change how many draws the run consumes based on whether the mod is
installed, at every single landing, for the rest of the run. `base()` runs
first and its result is used for exactly two things: detecting the nil case
(section 6.4) and nothing else. `test/run_tests.lua` section 9 is the test
that would catch a regression here, and it is deliberately run twice, once
under the Oath shrine's six-point pool and once under the ordinary full-map
pool, because those two cases draw a different number of times from FYShuffle
and a fix that only worked for one pool size would be a false all-clear on
the other.

## Why the scoping guard checks encounter.SpawnNearId, not just enemy.Name

`SelectSpawnPoint` is called for a great many things across the scripts,
including Eris's own summons (`HandleSpawnerBurst`'s `SpawnOnSpawnPoints`
branch, `EnemyAILogic.lua:4869-4871`). Both calls pass `enemy.Name == "Eris"`
as the same live enemy table, so name alone does not distinguish them. What
does: the fly-down teleport call (`EnemyAILogic.lua:1105`) sets
`args.RequireLoS = true` and `args.LoSTarget`, and the summon call's args
table is only `{ RecursiveWait = 0.03 }` -- neither is ever set there. This
mod's `isFlyDownTeleport` checks both `args.RequireLoS`/`args.LoSTarget` AND
that the third positional table's `SpawnNearId` equals the hero's `ObjectId`,
so a hypothetical future call shaped like the summon path but coincidentally
carrying a LoS check would still not match unless it were also aimed at the
hero specifically. `test/run_tests.lua` section 8 proves the summon call
produces byte-identical output to the real, unwrapped function, including an
identical RNG draw count.

## Why the ground marker attach/detach is keyed off DoWeaponFire, not a timer

`ErisFlyUp`/`ErisFlyUp_P4` and `ErisFlyDown` are named weapons, and
`DoWeaponFire` (`EnemyAILogic.lua:3923`) is called once per weapon fire with
`aiData.WeaponName` already stamped by `GetWeaponAIData`
(`EnemyAILogic.lua:5970`). That means the takeoff/landing transition is
observable directly, exactly the way RealHecate observes a split through
`UnitSplit` rather than inferring it -- no polling, no Z-height threshold
guessed at, no risk of the ground marker flickering visible for a frame while
she is still near the ground on the way up.

## Sabotage log

Every non-trivial test was sabotage-verified before shipping (`CONTRIBUTING.md`).
Two results are worth keeping because they taught something rather than just
confirming the obvious:

- **`isFlyDownTeleport`'s `SpawnNearId` clause needed its own direct test.**
  The first sabotage attempt removed only that clause (leaving the
  `RequireLoS`/`LoSTarget` check intact) and section 8's summon-passthrough
  test stayed green -- because the summon call's args have no `RequireLoS` at
  all, so it is rejected by the EARLIER check regardless of whether the
  `SpawnNearId` check does anything. This is rule 7 exactly: a guard is not
  proven by a test that never made execution depend on it. `test/run_tests.lua`
  section 8b calls `isFlyDownTeleport` directly with a shape that matches
  every OTHER clause but aims `SpawnNearId` at something other than the hero,
  and only that test went red when the clause was removed.
- **The freeze-on-landing guard is deliberately doubled, the same shape as
  RealHecate's split-generation guard.** `onFlyDown` both clears
  `AIRBORNE_FIELD` and bumps `LANDING_GENERATION_FIELD`; `watchLanding` checks
  both. Sabotaging only the generation bump left the freeze tests green,
  because the airborne check alone already stops the watcher. Sabotaging both
  together turned `test/run_tests.lua` 11.6/11.7 red. Belt and braces,
  deliberately, confirmed the same way RealHecate's own DESIGN.md records for
  its own pair of independent guards.

## Things considered and left out

- **Predicting the landing spot ahead of the poll.** Investigated and
  rejected outright by the spec (section 6.1): the spot is rolled at the
  instant of the teleport and is filtered by wherever the player is standing
  at that moment, which does not exist as an input until it happens. There is
  nothing to predict.
- **A cache of "eligible spots" refreshed less often than every poll.** The
  per-poll cost is one `IsSpawnPointEligible` call (a distance and a line of
  sight check), not a scan of the whole candidate list -- rebuilding the full
  eligible list only happens when the current spot actually goes bad. A
  cache would save checking one point ten times a second and cost the
  complexity of knowing when to invalidate it. Not worth it unless a
  playtest shows the per-poll cost actually matters.
- **A settings-driven poll rate.** The spec calls for starting at 0.1s and
  backing off toward RealHecate's proven 0.25s only if a playtest shows it
  costing frames (section 6.6). Exposing it as a setting before there is any
  evidence either number is wrong would be a dial nobody has a reason to
  move.
