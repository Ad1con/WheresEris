# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The release workflow folds the `[Unreleased]` section into the tagged
version, so the square brackets are load-bearing -- the action looks for
`[Unreleased]` exactly and fails the build without it.

## [Unreleased]

First build. Not yet released -- see the repository's `WHERES_ERIS_SPEC.md`
definition of done for what is still outstanding (playtest confirmation, in
particular whether the landing marker's art renders as expected -- see
DESIGN.md).

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
