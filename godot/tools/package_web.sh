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
echo "package_web.sh: serve it with, e.g., python -m http.server 8000 --directory $out"
