# DESIGN.md

Extended rationale for WheresEris. Repo-only, not packaged -- see
`thunderstore.toml`'s `[[build.copy]]` list, which names only `CHANGELOG.md`,
`LICENSE` and `src/`. The authoritative build specification is
`WHERES_ERIS_SPEC.md`, one level up in `Plugin Work/`, not part of this
repository. This file exists for anything that spec did not need to say but a
future reader of this code will want to know.

## Landing marker art: confirmed rendering, scale wrong -- 2026-09-09 playtest

The landing marker's art is the game's own keepsake face for Eris
(`GUI\Screens\AwardMenu\KeepsakeMaxGift\KeepsakeMaxGift_big\Eris`, inside
`GUI.pkg`), registered as a new Animation entry via `sjson.hook` on
`Game/Animations/GUI_Screens_VFX.sjson` and attached in the 3D world with
`CreateAnimation`. This was the one thing the offline suite could not verify
(MODDING_HADES2.md section 3 rule 6: it proves the logic, not whether a
texture renders). Caleb's first playtest confirms it renders -- a GUI-atlas
texture attached with `CreateAnimation` in the 3D world, not just
`CreateScreenComponent` on a 2D screen, which is now a technique this account
has verified rather than one it merely expects to work.

What playtest also showed: the marker was far larger than a character,
covering a large fraction of the screen. `LandingMarkerScale` shipped at 3.0,
copied from RealHecate's `ApolloGroundGlow` default -- a texture tuned to read
as "roughly one character footprint" at that value. The keepsake face is a
240x240 source image, much larger natively than whatever `ApolloGroundGlow`'s
own canvas is, and the registered Animation entry carries no `Scale` of its
own the way vanilla's ground sprites typically do, so the runtime `Scale`
argument multiplies straight off the full 240px source. The same number does
not transfer between two different source textures.

Fix: dropped the default to 0.5, estimated by eye against the screenshot, not
independently confirmed. `onFlyUp` and the `SelectSpawnPoint` wrap now log the
chosen spot id and the eventual teleport substitution
(`landing: teleporting to marked spot X (vanilla would have picked Y)`), so
the next playtest can confirm both the size and that the marker's spot is
really where she lands, from the log rather than a screenshot.

## The landing marker's lifecycle -- 2026-09-15 playtest, two fights

The 0.5 default above never reached the player. `Adicon-WheresEris.cfg` had
been written by the 3.0 build, and the file always beats the code default
(MODDING_HADES2.md section 4, first rule) -- so the fix shipped and the
portrait stayed 720px wide. A default change is not a fix on any profile that
already has the file; the .cfg has to move too, or the setting has to be
renamed.

The log from this morning also shows three lifecycle faults, all independent
of size.

**1. The marker is never cleared after a normal landing.** `onFlyDown` bumps
the landing generation, which retires `watchLanding` -- and `watchLanding` is
the only thing that ever calls `moveMarkerTo(nil)`, and only on death. So the
watcher is killed before it can clean up, `onFlyDown` does not clean up
either, and the portrait sits on the landing spot for the rest of the fight.
"Stayed on the screen" is exactly this.

**2. The stale marker redirects later teleports.** Because `LANDING_SPOT_FIELD`
is never cleared, every later `SelectSpawnPoint` finds it, and if the spot is
still eligible, sends her there instead of vanilla's pick:

```
11:37:03  landing: teleporting to marked spot 744610 (vanilla would have picked 744617)
11:37:14  landing: teleporting to marked spot 744610 (vanilla would have picked 744610)
```

Neither of those followed a takeoff. RNG parity survives (base ran first), but
her position does not: she was sent to a spot from a flight that ended a
minute earlier. That is the one thing this mod promised never to do.

**3. The teleport filter is too broad.** `isFlyDownTeleport` tests for
`RequireLoS` on the args and `SpawnNearId == hero`, and three weapons match:

```
ErisFlyDown           the landing this mod was written for
ErisRelocateStrike2   a teleport-strike, no flight
ErisRelocate_Down     the landing of a SECOND flight, see below
```

Fight one logged eighteen "marker was stale" landings and zero takeoffs. Those
were RelocateStrike2 and Relocate_Down teleports hitting the substitution path
with no marker to substitute. Harmless there, only because nothing had left a
marker behind yet.

**4. There is a second flight.** `ErisRelocate_Up` (and `_Up_P4`) chains to
`ErisRelocate_Down` (and `_Down_P4`), using `Enemy_Eris_FlyUp_Start_Fast` /
`Enemy_Eris_FlyUp_Fire_Fast`. It is the fast variant of the same maneuver.
`FLY_UP_WEAPONS` and `FLY_DOWN_WEAPON` name only `ErisFlyUp*` and
`ErisFlyDown`, so during a Relocate flight the ground marker stays attached
and floats with her, and no landing marker is placed.

### The fixes

* `onFlyDown` calls `moveMarkerTo(game, enemy, nil)`. Safe, because the
  DoWeaponFire wrap runs `base()` first and the teleport -- and therefore the
  `SelectSpawnPoint` substitution -- happens inside `base()`. By the time
  `onFlyDown` runs, the marker has already done its job.
* The `SelectSpawnPoint` wrap substitutes only while `enemy[AIRBORNE_FIELD]` is
  true. A teleport that did not follow a tracked takeoff cannot be redirected,
  whatever `LANDING_SPOT_FIELD` holds. This makes fault 2 impossible even if
  fault 1 ever comes back.
* `FLY_UP_WEAPONS` gains `ErisRelocate_Up` and `ErisRelocate_Up_P4`;
  `FLY_DOWN_WEAPON` becomes a set holding `ErisFlyDown`, `ErisRelocate_Down`,
  `ErisRelocate_Down_P4`.
* `LandingMarkerScale` default and the live .cfg both go to 1.0 -- 240px, about
  half her footprint. Caleb adjusts from there.

### The early highlight, since he asked

He likes that the outline and ground marker appear a beat before her model
does. That is not prediction; it is hook timing, twice over. `SetupUnit` marks
her the instant the unit exists, before her entrance animation has played. And
on every landing, `onFlyDown` runs after `base()`, which includes the teleport
-- so the ground marker reappears at the destination while the descent
animation is still finishing. Both are stable side effects of where the hooks
sit and cost nothing. Worth knowing so nobody "fixes" them.

## Why the landing glow is re-registered rather than reusing ApolloGroundGlow

Second 2026-09-15 playtest: the glow landing marker, tinted Cyan, read as red.
So did the outline and the ground marker, which ARE red -- but the point is
that Cyan looked no different.

`ApolloGroundGlow` is defined with `GroupName = "FX_Terrain_Add"` and a baked
`Red = 1, Green = 0.6, Blue = 0`. Additive means the sprite's color is added to
whatever is under it. Eris's floor is red and orange lava, so an additive red
adds nothing visible and an additive cyan adds to red and comes out pale pink.
RealHecate's DESIGN.md hit the identical wall on Hecate's cyan floor and
concluded "additive light can only ever wash toward white -- arithmetic, not a
bug." Red works for her only because red on cyan happens to be far apart.

So `WheresEris_LandingGlow` is registered via the same `sjson.hook` as the
portrait, as a **copy** of `ApolloGroundGlow`'s definition with
`GroupName = "FX_Terrain"` (the plain alpha-blended terrain group, and the most
common one in the game's own files) and `Red = Green = Blue = Alpha = 1`, so the
runtime `Color` is the drawn color rather than a multiplier on orange. The
ground marker under her keeps the original additive glow -- red-on-red is her
problem too, but she is also outlined, and it is not the thing a player is
running toward.

**Why a copy and not `InheritFrom`.** The first version inherited, and the
third playtest of the day drew nothing at all. The engine said why:

```
[ERR] AnimationData.cpp:218 WheresEris_LandingGlow trying to inherit from
      ApolloGroundGlow which does not exist
```

`InheritFrom` resolves at parse time, in file load order, and
`GUI_Screens_VFX.sjson` is read before `Melinoe_Apollo_VFX.sjson` defines the
parent. The entry ended up with no `FilePath`. Vanilla's own inheriting entries
all sit in the same file as their parent, later in it. An entry a mod injects
into a file the parent is not in must carry every field itself -- the
`FilePath`, the frame count and speed, the loop flag -- or it is an animation
of nothing. `Scale = 0.33` is copied too, so the runtime `Scale` argument means
the same thing for this marker as for the ground marker.

**And it is `Material = "Unlit"`.** Fourth playtest: the copy rendered, and it
rendered red. The texture is pure white (sampled: 255/255/255 at center,
quarter and edge), the tint resolved to White, the entry's own color is
neutral -- so the red was applied *after* we handed it over. A sprite with no
`Material` is shaded by scene light, and Eris's arena is lit blood-red. The
original never declared a material because additive sprites skip lighting;
the moment it moved to the plain group, the arena painted it. 99 vanilla
`FX_Terrain` entries are `Unlit`, `LobWarningDecalIris` among them -- a
where-the-attack-lands decal, which is what this is.

Test 18.3c asserts the entry has a `FilePath` and no `InheritFrom`; 18.3d that
the group is not additive; 19.1 that it is unlit. All fail if put back.

## The watcher retires when the landing is committed, not at touchdown

Same playtest: "picks one location, then goes to another and back." The log:

```
landing: teleporting to marked spot 744609
landing marker moved: 744609 -> 744610      <- after the landing
```

`SelectSpawnPoint` fixes her destination early in the fly-down attack. The
descent animation runs on for a while after. In that window the watcher was
still polling, saw the spot she was now occupying as ineligible, and moved the
marker away from her -- as she was visibly arriving. `onFlyDown` then cleared
it. So the marker was right, then wrong, then gone.

The substitution now bumps the landing generation itself, retiring the watcher
at the moment her destination is fixed. The marker stays put through the
descent and `onFlyDown` clears it at touchdown, as before. And if the marked
spot went bad at the last instant and vanilla's own pick is used, the marker
moves to *that* spot rather than sitting on one she will not use. Tests
19.2-19.9; the retire is sabotage-verified (three failures without it).

## The strike marker, and why its hook is the only one that runs before base()

`ErisRelocateStrike` winds up for 0.5s (PreAttack 0.225 + Fire 0.275) and
chains to `ErisRelocateStrike2`, which has `PreAttackTeleport = true` and
`PreAttackDuration = 0`. `HandleEnemyTeleportation` (EnemyAILogic.lua) sends
it through `SelectSpawnPoint` with `SpawnNearId = hero, SpawnRadius = 1000,
RequireLoS = true` and no required spawn-point type -- the same call shape as
the landing outside the Oath. So the landing's mechanism transfers whole:
pick with the same eligibility call, mark, substitute after `base()` has drawn
vanilla's own number.

Two things differ from the landing.

**The marker goes up BEFORE `base()`.** `DoWeaponFire`'s `base()` yields
through the entire attack. For the takeoff that is fine -- she is airborne for
seconds afterwards and the marker placed on return has plenty of time. For
the strike, the windup IS the attack: place the marker after `base()` returns
and it appears at the instant of the teleport, then vanishes. This is the one
hook in the file that runs pre-base, and the harness now records weapon and
animation events in one stream so 20.8b can assert the order; the mock
`base()` cannot yield, so it could not have caught this any other way.

**It has its own field.** `STRIKE_SPOT_FIELD`, not `LANDING_SPOT_FIELD`, and
its own color. She cannot be winding up a strike while airborne, so the two
never contend for `SelectSpawnPoint` -- the strike branch is gated on
`STRIKE_PENDING_FIELD`, the landing on `AIRBORNE_FIELD`, and a stale value in
either field with its gate down redirects nothing (20.15, 11.8).

No watcher. A half-second window is not long enough for a re-pick to help,
and the substitution already handles a spot that went bad at the last instant
by moving the marker to vanilla's pick.

Off by default. Half a second is the game's own telegraph for the move, so it
is real information -- but whether a flash that short reads as a cue or as
noise is a taste call, and the player is the one to make it.

## PreferredSpawnPointGroup -- traced and ruled out, not overlooked

A review pass over the real `HandleEnemyTeleportation` call site
(`EnemyAILogic.lua:1106`) noticed two fields this file's `eligibilityArgs`
does not reconstruct: `PreferredSpawnPoint` and `PreferredSpawnPointGroup`,
both read from `aiData`. `EnemyData_Eris.lua`'s stage 2 data does set
`PreferredSpawnPointGroup = "SpawnPointsPhase2"`, which was worth chasing down
rather than dismissing.

It traced to nothing this mod needs to handle, for a specific reason worth
recording so a future reader does not re-open it: that assignment lives
inside stage 2's `EMStageDataOverrides`, and `StagedAI` only merges
`EMStageDataOverrides` onto a stage at all when
`IsBossDifficultyShrineUpgradeActive()` is true (`EnemyAILogic.lua:5615-5617`)
-- the exact same oracle this mod already reads as `isBossDifficultyActive`.
So `aiData.PreferredSpawnPointGroup` is only ever non-nil under the same
condition that also sets `aiData.TeleportToSpawnPointType = "EnemyPointSupport"`
(`WeaponData_Eris.lua`'s `ErisFlyDown` `ConditionalData`) -- and
`SelectSpawnPoint`'s own branch order checks `RequiredSpawnPoint` (fed by
`TeleportToSpawnPointType`) BEFORE `PreferredSpawnPointGroup`
(`EncounterLogic.lua:1084` vs `:1097`, an `if`/`elseif` chain). Whenever
`PreferredSpawnPointGroup` could possibly be set, `RequiredSpawnPoint` is
already set too and wins the branch first. Outside the Oath shrine, neither
field is ever populated for this weapon. The two-way branch this mod already
has -- `EnemyPointSupport` under Oath, the whole map otherwise -- is therefore
the complete answer for `ErisFlyDown` specifically, not a simplification of a
more complex real rule.

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
Three results are worth keeping because they taught something rather than just
confirming the obvious:

- **`MARKED_FIELD` was written but never checked, found on a later review
  pass.** `attachIdentifier` set it unconditionally and nothing read it, so a
  second `SetupUnit` call on the same live Eris would have stacked a second
  ground sprite -- `CreateAnimation` is not idempotent the way `AddOutline` is
  (MODDING_HADES2.md section 2's "accumulates" hazard). No test caught it
  because no test called `SetupUnit` twice. Fixed by gating both attach calls
  on `not enemy[MARKED_FIELD]`, matching RealHecate's equivalent guard;
  `test/run_tests.lua` 3.13/3.14 calls `SetupUnit` twice and asserts exactly
  one of each. `detachOutline` was removed rather than wired in: it had no
  caller either, but this mod's design (mark once, outline stays for the
  whole fight) has no scenario that needs one.

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
