#!/usr/bin/env sh
#
# Build the GDExtension and put the shared library where Godot loads it.
#
#   crates/godot/build.sh            # debug
#   crates/godot/build.sh release    # release
#
# Godot only loads libraries under `res://`, and it will not scan a Cargo build
# directory, so the artifact is copied into `godot/addons/goats_godot/bin/`
# rather than referenced out of `target/`. `godot/goat.gdextension` names those
# paths.
#
# After the first build, open the project once (or run
# `Godot --headless --path godot --import`) so Godot scans the descriptor; a
# godot-rust library is not registered until that pass has run.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
godot_dir=$here/../../godot

profile=debug
cargo_flags=
if [ "${1:-}" = "release" ]; then
    profile=release
    cargo_flags=--release
fi

cargo build -p goats-godot $cargo_flags

# The crate names no `target-dir`, so the workspace's is two levels up.
target_dir=$here/../../target

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows*)
        platform=windows
        lib_name=goats_godot.dll
        ;;
    Darwin)
        platform=macos
        lib_name=libgoats_godot.dylib
        ;;
    *)
        platform=linux
        lib_name=libgoats_godot.so
        ;;
esac

src=$target_dir/$profile/$lib_name
dest=$godot_dir/addons/goats_godot/bin/$platform

if [ ! -f "$src" ]; then
    echo "build.sh: expected the library at $src" >&2
    exit 1
fi

mkdir -p "$dest"
cp "$src" "$dest/"
echo "build.sh: copied $profile/$lib_name -> addons/goats_godot/bin/$platform/"
