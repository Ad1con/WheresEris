# Contributing

## Tests

```bash
cd test && lua run_tests.lua
```

Run them on both interpreters -- the game ships LuaJIT, and the two differ in
ways that have caught real bugs in sibling mods on this account.

```bash
winget install DEVCOM.Lua
winget install LuaJIT.LuaJIT
```

## Sabotage every new test

After writing a test, reintroduce the bug it is meant to catch and confirm
that test goes red, then revert. It takes thirty seconds.

This is not ceremony. A passthrough test that only checks one outcome (base
returns X) will not notice logic that always forces X regardless of the
setting under test, because both agree by accident. Every non-trivial test in
this suite was sabotage-verified before shipping, in both directions where the
behavior has two.

## Do not edit while the game is running

`plugins/Adicon-WheresEris` in r2modman is a junction to `src/`, so every save
there is a live edit to the running game. The loader picks it up within
seconds and re-runs the plugin chunk.

Source `guard.sh` and call `guard` before any write to `src/`:

```bash
. ./guard.sh && guard || exit 1
```

See `MODDING_HADES2.md` section 2 for why this matters: hot-reloading
mid-session crashed a live fight during a sibling mod's development.

## The RNG-parity test is load-bearing

`SelectSpawnPoint` shuffles with the run's own seeded RNG. This mod's wrap
calls the real function first, unconditionally, so it consumes exactly the
draws vanilla would, and only substitutes its own choice afterward. The suite
asserts the draw count is identical whether the mod is enabled or not
(`test/run_tests.lua`, section 9). Do not "optimize" the wrap to skip the real
call when the mod's own pick is already known -- that is precisely the
optimization this test exists to catch.

## Layout

`src/` is what ships. Everything else -- tests, docs, `guard.sh` -- does not.
`thunderstore.toml` maps `./src` to `./plugins` at build time.
