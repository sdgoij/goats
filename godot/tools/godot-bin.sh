#!/usr/bin/env sh
#
# Print the Godot executable to use, and say how it was found.
#
#   godot/tools/godot-bin.sh          # the path, or the reason there is none
#   godot_bin=$(sh godot/tools/godot-bin.sh)
#
# Every tool here that needs the editor asks this one question, so there is a
# single answer to "which Godot": `gates.sh`, `interop.sh` and `package_web.sh`
# call this, and `gdscript_warnings.py` runs it through `sh` -- one search, not
# four. A machine only has to be told once.
#
# `GODOT_BIN` is the override, and it may name a *command* (`GODOT_BIN=godot`)
# as well as a path, because both are what people have to hand. Without it the
# search is, in order:
#
#   1. `godot`, `godot4` and `Godot` on `PATH` -- a packaged install, a symlink, a
#      scoop/winget shim;
#   2. the repository's own `godot-bin/`, which is where CI unpacks the release;
#   3. the places a downloaded editor usually ends up: `~/bin`, `~/Downloads`,
#      `~/Desktop`, `~/Applications`, and on Windows
#      `%LOCALAPPDATA%/Programs/Godot` and `~/AppData/Local/Programs/Godot`;
#   4. the system locations: `/usr/bin`, `/usr/local/bin`, `/opt/godot`, Snap,
#      Flatpak exports, and the macOS bundle at `/Applications/Godot.app`.
#
# Each directory is scanned for `Godot*` and the last name in order wins. Every
# release is called `Godot_v4.x.y-stable...`, so name order is version order for
# the minors anyone hits in practice, and that prefers the newest copy of a
# folder full of downloads.
#
# The finding and its version go to stderr, so stdout is the answer. A build that
# is not 4.7.x is a *warning*, not a refusal: the extension and its gates are
# built against 4.7.2's API, and a warning here reads better than the gate
# failures that follow. Exits 1, listing every place it tried, when nothing is
# found.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# Report a finding and answer with it: $1 the executable, $2 the rule that found it.
report() {
    echo "godot-bin: ${1} (${2})" >&2
    version=$("$1" --version 2>/dev/null | head -1) || version=""
    case "$version" in
        4.7.*) : ;;
        "") echo "godot-bin: warning: $1 did not answer --version" >&2 ;;
        *) echo "godot-bin: warning: this is Godot ${version}; the port and its gates are built" \
               "against 4.7.2's API" >&2 ;;
    esac
    printf '%s\n' "$1"
}

# A command on PATH, if there is one.
as_command() {
    found=$(command -v "$1" 2>/dev/null) || return 1
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

# The last `Godot*` executable in a directory, which is the newest by name.
newest_in() {
    [ -d "$1" ] || return 1
    found=""
    for candidate in "$1"/Godot*; do
        [ -f "$candidate" ] || continue
        [ -x "$candidate" ] || continue
        found=$candidate
    done
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

if [ -n "${GODOT_BIN:-}" ]; then
    if [ -f "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ]; then
        case "$GODOT_BIN" in
            /* | [A-Za-z]:[\\/]*) resolved=$GODOT_BIN ;;
            *) resolved=$(CDPATH= cd -- "$(dirname -- "$GODOT_BIN")" && pwd)/$(basename -- "$GODOT_BIN") ;;
        esac
        report "$resolved" "GODOT_BIN"
        exit 0
    fi
    if found=$(as_command "$GODOT_BIN"); then
        report "$found" "GODOT_BIN, a command"
        exit 0
    fi
    echo "godot-bin: GODOT_BIN=$GODOT_BIN is not an executable file and not on PATH" >&2
    exit 1
fi

for name in godot godot4 Godot; do
    if found=$(as_command "$name"); then
        report "$found" "PATH"
        exit 0
    fi
done

if found=$(newest_in "$root/godot-bin"); then
    report "$found" "$root/godot-bin"
    exit 0
fi

home=${HOME:-}
for dir in "$home/bin" "$home/Downloads" "$home/Desktop" "$home/Applications" \
    "${LOCALAPPDATA:-}/Programs/Godot" "$home/AppData/Local/Programs/Godot"; do
    [ -n "$dir" ] || continue
    if found=$(newest_in "$dir"); then
        report "$found" "$dir"
        exit 0
    fi
done

for path in /usr/bin/godot /usr/local/bin/godot /opt/godot/godot /snap/bin/godot \
    "$home/.local/share/flatpak/exports/bin/org.godotengine.Godot" \
    /var/lib/flatpak/exports/bin/org.godotengine.Godot \
    /Applications/Godot.app/Contents/MacOS/Godot \
    "$home/Applications/Godot.app/Contents/MacOS/Godot"; do
    if [ -f "$path" ] && [ -x "$path" ]; then
        report "$path" "a system location"
        exit 0
    fi
done

cat >&2 <<'MESSAGE'
godot-bin: no Godot found. Either set GODOT_BIN to the 4.7.2 executable, or put
one on PATH under the name `godot` (a symlink is enough). Everything tried:
  - godot, godot4, Godot on PATH
  - <repo>/godot-bin/
  - ~/bin, ~/Downloads, ~/Desktop, ~/Applications, %LOCALAPPDATA%/Programs/Godot
  - /usr/bin, /usr/local/bin, /opt/godot, Snap, Flatpak exports, /Applications/Godot.app
MESSAGE
exit 1
