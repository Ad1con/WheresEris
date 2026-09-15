# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The release workflow folds the `[Unreleased]` section into the tagged
version, so the square brackets are load-bearing -- the action looks for
`[Unreleased]` exactly and fails the build without it.

## [Unreleased]

### Added

- **A strike marker, off by default.** `ErisRelocateStrike` winds up for half a
  second and then teleports through the same spawn-point call her landing
  uses, so the same trick applies: mark during the windup, substitute on the
  teleport. Exact, not a guess. `StrikeMarker = true` to turn it on;
  `StrikeMarkerColor` defaults to Magenta so it never reads as a landing.

### Changed

- **The landing marker is a solid white glow, twice her size.** The ground
  glow's art, re-registered without its additive blending and baked orange, so
  the color you pick is the color on the floor -- on Eris's red arena the
  original additive glow could only ever read as red, whatever it was tinted.
  The keepsake portrait is kept as `LandingMarkerStyle = Portrait`, drawn at two
  thirds of its previous size.
- **`LandingMarkerScale` is a multiplier on the style's own normal size.** 1 is
  right for either art, 2 is twice that. If your config still says `Red` for
  `LandingMarkerColor` from an earlier build, the file beats the default -- set
  it to `White` yourself, or pick any color you like.
- Teleports this mod never marked now log as `teleport (not a marked landing)`
  rather than `marker was stale`, which read as a fault when nothing was wrong.

### Fixed

- **The landing marker now disappears when Eris lands.** It used to stay on the
  landing spot for the rest of the fight -- and worse, because it was never
  cleared, later teleports could be redirected to it: Eris sent to a spot from a
  flight that ended a minute earlier. Only a landing that follows a takeoff can
  be redirected now.
- **Her fast flight is tracked.** `ErisRelocate_Up`/`_Down` is the same
  maneuver at speed and was missed; the ground marker floated with her through
  it and no landing marker was placed.
- **`LandingMarkerScale` defaults to 1.** If your config still says 3 from an
  earlier build, the marker is drawn three times too large -- the file beats the
  default, so set it yourself.

First build. Not yet released -- see the repository's `WHERES_ERIS_SPEC.md`
definition of done for what is still outstanding.

First playtest (2026-09-09) confirmed the landing marker renders. Its default
size did not: `LandingMarkerScale` shipped at 3.0, copied from RealHecate's
ground-marker default, and rendered far larger than a character against the
keepsake-face texture. Dropped to 0.5, an estimate pending confirmation. See
DESIGN.md.

- Outlines Eris and gives her a colored ground marker while she is standing on
  the ground, in RealHecate's own palette and settings vocabulary.
- Shows a marker on the spot Eris will land on, from the instant she takes off
  to the instant she touches down. The spot is always one the game itself
  would have accepted at that moment: eligibility is judged entirely by the
  real `IsSpawnPointEligible`, never a rule this mod invented.
- Does not alter the run's seed. `SelectSpawnPoint` always runs for real
  first, so it draws exactly what vanilla would; only its result is
  substituted.
- Applies to the ordinary fight, the Rivals bounty fight, and Dream Dives.
  Vanilla already outlines her in a Dream Dive; this mod's own outline doubles
  up on top of it by default, behind `OutlineInDreamDives`.
- Twelve settings, all on a panel in the modding overlay: `Enabled`, `Outline`,
  `OutlineColor`, `OutlineThickness`, `OutlineOpacity`, `OutlineInDreamDives`,
  `GroundFx`, `GroundFxColor`, `GroundFxScale`, `LandingMarker`,
  `LandingMarkerColor`, `LandingMarkerScale`.
- Writes nothing to the save. See the README's Compatibility section.
