# Working in this repository

## Validation: a passing test is not a passing suite

The cases that name your change can pass while one in a crate you never opened
fails. That is the failure mode this file exists for -- it has cost this
repository a CI round more than once. So run what CI runs
(`.github/workflows/ci.yml`), all of it, before claiming anything is green:

```sh
# 1. The crates that need no engine (CI's `Crates` job).
cargo test --workspace --exclude goats --exclude goats-android --exclude harness \
    --exclude goats-godot --exclude plugin --exclude server --exclude flight-js

# 2. The whole scene on the engine, ignored cases included (CI's `Scene tests`).
cargo test --profile fast -p harness -- --include-ignored --nocapture

# 3. The crates that link the engine (the same job's second step).
cargo test --profile fast -p plugin -p server -p flight-js -p goats-godot

# 4. The client's own cases (CI's `Build` job).
cargo test --release -p goats

# 5. The port, when `godot/**/*.gd` or `godot/**/*.gdshader` changed.
GODOT_BIN=<godot 4.7.2> sh godot/tools/gates.sh
```

`README.md`'s *Tests and tools* carries the same list with the reasoning; if the
two ever disagree, CI is the truth.

Also run `cargo clippy --workspace --all-targets -D warnings`: the pre-commit
hook does, and `godot/tools/gdscript_warnings.py` when staged GDScript changed.

### The trap that keeps catching us: a world mod's signature

`side: "world"` mods are hashed, and the shipped example is pinned. **Editing
any file that is part of the mod's runtime surface moves the digest**, and the
test that holds it lives in a crate `-p harness` never builds:

- `mods/birds/mod.js` (the entry text) and `mods/birds/mod.json` (id, version,
  tuning, asset names and bytes) **are** the signature -- `APIv1.md` §6.2.
- `mods/birds/FLIGHT.md` is documentation and is **not** hashed, so notes and
  warnings belong there rather than in the entry, where a comment is a new
  signature.
- The pin is `the_birds_fixture_digest_is_pinned` in `crates/mods/src/lib.rs`.
  Moving it is a deliberate act, not a fix-up: bump the mod's version, paste the
  digest the failure prints, and write the move up in the ROADMAP's M14d. It is
  a compatibility boundary -- a peer on the old birds cannot join a host on the
  new ones.

So a change that is "only a mod" still needs command 1, not just command 2.

### The Godot port is not Rust

A `godot/src/*.gd` edit is invisible to `cargo test`. `godot/tools/gates.sh` is
the port's own conformance suite (42 gates, which parse every script), and
`gdscript_warnings.py` is the one that fails on `INTEGER_DIVISION`,
`SHADOWED_VARIABLE` and friends. Both need `GODOT_BIN` pointing at a 4.7.2
binary.

## The code is the documentation

Long comments here explain *why* a number is what it is, what was tried first and
what it cost -- see `weather.js`'s slab constants, `terrain.js`'s seam strip, or
the ROADMAP's milestone write-ups. A change that moves a rule should move the
paragraph that explains it, and a new tuning leaf should say what it is for.
