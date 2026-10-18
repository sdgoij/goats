#!/usr/bin/env sh
#
# Package the browser build: export the Godot client into `<out>/client/` and
# put the shell page beside it at `<out>/index.html` (`godot/WEB.md`).
#
#   GODOT=/path/to/Godot sh godot/tools/package_web.sh [out]
#
# `out` defaults to `target/godot-web`. The shell (`godot/web/index.html`) is
# plain, dependency-free HTML: it frames the client at a 16:9 stage, offers a
# client switcher, and holds the mod editor's place in the page. The reference
# client, when its browser build exists, goes under `<out>/reference/`.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
godot_dir=$root/godot
out=${1:-$root/target/godot-web}
godot=${GODOT:-${GODOT_BIN:-godot}}

if [ ! -f "$godot_dir/addons/goats_godot/bin/web/goats_godot.wasm" ]; then
    echo "package_web.sh: no web extension yet -- run godot/tools/build_web.sh first" >&2
    exit 1
fi

mkdir -p "$out/client"
# Godot resolves a relative output path against `--path`, not the caller's cwd,
# so make `out` absolute before handing the file path over.
out=$(CDPATH= cd -- "$out" && pwd)

# The two mods the desktop release carries, staged as zips for the export's
# `bundled_mods/*` include filter. A zip is what keeps the mod's raw bytes
# (`mod.js`, a `.glb`, `.mp3`): Godot imports a raw media file into its own
# resource, so the loader would otherwise never see the file the manifest names.
# `mods.gd` reads these back with `ZIPReader` on boot.
stage=$godot_dir/bundled_mods
rm -rf "$stage"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT INT TERM
python_bin=""
for candidate in "${PYTHON:-}" python3 python py; do
    [ -n "$candidate" ] || continue
    if "$candidate" -c 'import shutil' >/dev/null 2>&1; then
        python_bin=$candidate
        break
    fi
done
if [ -z "$python_bin" ]; then
    echo "package_web.sh: need python3 (or python/py) with shutil for the bundled mod zips" >&2
    exit 1
fi
for mod in birds fatguy; do
    if [ ! -d "$root/mods/$mod" ]; then
        echo "package_web.sh: missing $root/mods/$mod" >&2
        exit 1
    fi
    "$python_bin" -c 'import shutil,sys; shutil.make_archive(sys.argv[1], "zip", sys.argv[2])' \
        "$stage/$mod" "$root/mods/$mod"
    if [ ! -f "$stage/$mod.zip" ]; then
        echo "package_web.sh: $mod.zip was not created" >&2
        exit 1
    fi
done

# Godot wants a host path; MSYS/Git Bash paths (`/c/...`) are not it.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        godot_path=$(cygpath -m "$godot_dir")
        out_html=$(cygpath -m "$out/client/index.html")
        ;;
    *)
        godot_path=$godot_dir
        out_html=$out/client/index.html
        ;;
esac

# Godot does not create the output directory; `mkdir` above did. This writes
# index.html, index.js, index.wasm, index.side.wasm, index.pck and the
# extension into `client/`.
echo "package_web.sh: exporting Web -> $out/client/"
"$godot" --headless --path "$godot_path" --export-release "Web" "$out_html"

cp "$godot_dir/web/index.html" "$out/index.html"
echo "package_web.sh: shell -> $out/index.html"

# The raylib client's own browser build (`web/build.sh client`). It is a
# separate build from the Godot one, so a Godot-only package simply omits it;
# the shell's HEAD probe then leaves the switcher's Reference option disabled.
reference=$root/web/dist
if [ -f "$reference/index.html" ] && [ -f "$reference/goats.js" ] && [ -f "$reference/goats.wasm" ]; then
    rm -rf "$out/reference"
    mkdir -p "$out/reference"
    cp "$reference"/* "$out/reference/"
    echo "package_web.sh: reference -> $out/reference/"
else
    rm -rf "$out/reference"
    echo "package_web.sh: no reference build in web/dist (run web/build.sh client)"
fi
echo "package_web.sh: serve it with, e.g., python -m http.server 8000 --directory $out"
