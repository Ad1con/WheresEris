# WheresEris

**Outlines Eris and marks the spot she will land on, from takeoff to touchdown.**

Eris gets a colored outline and a colored marker on the ground beneath her, in
the same colors and settings as RealHecate. When she flies up to bombard, a
marker appears on the spot she will land on and stays there until she does,
moving only if your position makes it stop being a legal spot.

Works in the ordinary fight, the Rivals bounty fight, and Dream Dives. Vanilla
already outlines Eris in a Dream Dive; this mod's own outline is added on top
of vanilla's by default, so a Dream fight reads as a heavier, more solid
version of the same red rather than a second color.

This is a real change to the fight. Eris will land where this mod chose,
taken from the same set of spots the game itself would have used.

## Settings

The config file is `Adicon-WheresEris.cfg`, in your profile's
`ReturnOfModding\config` folder. Every setting is also on the **WheresEris**
panel in the modding overlay.

Edit the file with the game **closed**. Hades II rewrites it from memory on
exit, so changes made while it is running are discarded.

| Setting | Default | What it does |
|---|---|---|
| `Enabled` | `true` | Master switch. Set to `false` for vanilla. |
| `Outline` | `true` | Outline Eris's silhouette. |
| `OutlineColor` | `Red` | Color of the outline. |
| `OutlineThickness` | `6` | 1-10. The game's own elite outlines are `3`. |
| `OutlineOpacity` | `1.0` | 0-1. The game's own are `0.8`. |
| `OutlineInDreamDives` | `true` | Add this mod's outline in Dream Dives, on top of vanilla's own. Set to `false` to leave a Dream run outlined exactly as the game made it. |
| `GroundFx` | `true` | Show a colored marker on the ground under Eris while she is standing on it. Hidden while she is airborne. |
| `GroundFxColor` | `Red` | Color of the ground marker, or `None` to leave the art its own gold-orange. |
| `GroundFxScale` | `3` | Size of the ground marker. |
| `LandingMarker` | `true` | Show the spot Eris will land on, from takeoff to touchdown. |
| `LandingMarkerColor` | `Red` | Tint of the landing marker. |
| `LandingMarkerScale` | `3` | Size of the landing marker, against the arena's own scale. |

**Colors** for `OutlineColor`, `GroundFxColor` and `LandingMarkerColor`:
`Amber` `Ember` `Violet` `Gold` `Teal` `Cyan` `Green` `Magenta` `Red` `White`

Red is the default for all three: the strongest available contrast against
this game's arena floors.

## How it works

Eris teleports to a new spot at the instant she starts descending, chosen by
the game from whichever of its own spawn points currently pass distance and
line-of-sight checks against your position. That choice does not exist until
the instant it happens, so this mod cannot predict it. Instead it chooses the
spot itself, from the same eligible set the game's own rules would allow, and
substitutes that choice for the game's. Every candidate is checked against
the game's own `IsSpawnPointEligible` function; nothing here invents its own
idea of a legal spot. The marker rechecks its spot ten times a second while
she is airborne and freezes the instant she starts landing.

**This mod does not change your run's seed.** The game still rolls for where
Eris lands, and that roll advances the random sequence exactly as it would
without the mod. What changes is which of the legal spots gets used.

If a summoned add is standing on the last free spawn point and squeezes out
every option, the marker disappears and Eris does not teleport at all. That
is what the vanilla fight already does under the Oath of the Underworld
shrine; this mod matches it rather than working around it.

## Compatibility

Modifies no game files. It wraps three functions -- `SetupUnit`,
`DoWeaponFire` and `SelectSpawnPoint` -- and attaches art that already ships
with the game. Nothing is written to your save, and nothing here reaches past
the fight it happened in.

## Credits

Hades II is by [Supergiant Games](https://www.supergiantgames.com/). This is
an unofficial fan mod, not endorsed by or affiliated with them. The mod icon
is a cropped in-game portrait, and the landing marker reuses her own keepsake
face from the game's award screen, unaltered.

Built on [ReturnOfModding / Hell2Modding](https://github.com/SGG-Modding).
This mod cannot load without `LuaENVY-ENVY`, `SGG_Modding-ModUtil`,
`SGG_Modding-ReLoad` and `SGG_Modding-SJSON` -- the environment isolation, the
function wrapping, the hot reload and the landing marker's art registration
are all theirs.

Thank you to the Hades Modding community. Your work is astounding.

Built by Adicon, with Claude.
