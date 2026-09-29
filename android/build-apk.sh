#!/usr/bin/env bash
#
# The APK: a `NativeActivity` around the client's cdylib, by hand.
#
# Gradle is not used on purpose: the artifact is one `.so`, one `classes.dex`, a
# manifest and no resources, and `javac` + `d8` + `aapt2` + `zipalign` +
# `apksigner` are all in the SDK and the JDK. A Gradle project would add a build
# tool that has to be downloaded and a plugin that has to match it, for nothing
# this build does (ANDROID.md D6).
#
# Run it after `cargo build --release -p goats-android --target aarch64-linux-android`
# -- or after a bare `cargo build` for the `debug` profile, which is the loop rather
# than the game (see ANDROID.md's "The build, concretely" for the environment that
# needs). It is the same script on Linux -- which is where CI runs it -- and on
# Windows, where it was written: the host decides the tool names, and the SDK and the
# NDK come from the environment the way a developer and a runner both set it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"
APK="$OUT/goats.apk"
LIB="lib/arm64-v8a/libgoats_android.so"

# ---- the profile ----------------------------------------------------------
# The one argument names the cargo profile to package, which is also the directory
# cargo put the library in. `release` by default, because this script's product is
# the APK you install: it is the profile the game ships and the one `PERF.md`
# measures (README, "Building"), where `dev` is opt-level 1 with overflow checks on
# -- the loop, not the game. `debug` is for iterating on the phone, and wants a
# `cargo build` without `--release`.
PROFILE="${1:-release}"
case "$PROFILE" in
    debug | release) ;;
    *)
        echo "goats-android: usage: $(basename "$0") [debug|release]" >&2
        exit 2
        ;;
esac
SO="$ROOT/target/aarch64-linux-android/$PROFILE/libgoats_android.so"

# ---- the host -------------------------------------------------------------
# The SDK's build-tools are per-host: Windows has `d8.bat` and `.exe` binaries,
# everyone else has extension-less scripts. The NDK's prebuilt tree is per-host too.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        EXE=".exe"; NDK_HOST="windows-x86_64"; D8="d8.bat"; APKSIGNER="apksigner.bat"
        # `$HOME` rather than `$LOCALAPPDATA`: inside these shells the former is a
        # POSIX path and the latter is a Windows one, backslashes and all.
        DEFAULT_SDK="$HOME/AppData/Local/Android/Sdk"
        ;;
    Darwin)
        EXE=""; NDK_HOST="darwin-x86_64"; D8="d8"; APKSIGNER="apksigner"
        DEFAULT_SDK="$HOME/Library/Android/sdk"
        ;;
    *)
        EXE=""; NDK_HOST="linux-x86_64"; D8="d8"; APKSIGNER="apksigner"
        DEFAULT_SDK="$HOME/Android/Sdk"
        ;;
esac

# ---- the tools ------------------------------------------------------------
# The build-tools and the platform are the *newest installed* rather than a pinned
# version, so a runner image that moves on does not break the build.
if command -v python3 >/dev/null 2>&1; then PYTHON="${PYTHON:-python3}"; else PYTHON="${PYTHON:-python}"; fi

# The newest of some already-expanded glob, by version -- an empty match is not an
# error here, because the loop below is what reports a package by name.
newest() {
    for d in "$@"; do
        if [ -d "$d" ]; then printf '%s\n' "$d"; fi
    done | sort -V | tail -1
}

# The first candidate that actually looks like an SDK. `ANDROID_SDK_ROOT` is what a
# runner sets, `ANDROID_HOME` what an older developer setup sets, `ANDROID_SDK`
# what this script used to read -- and on Windows all of them arrive with
# backslashes, and some setups point at the Android directory rather than the SDK
# inside it, hence the `/Sdk` retry.
pick_sdk() {
    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        candidate="${candidate//\\//}"
        case "$candidate" in */) candidate="${candidate%/}" ;; esac
        if [ -d "$candidate/build-tools" ]; then printf '%s\n' "$candidate"; return 0; fi
        if [ -d "$candidate/Sdk/build-tools" ]; then printf '%s\n' "$candidate/Sdk"; return 0; fi
    done
    # Nothing looked like an SDK: name the first thing we were given, so the error
    # below reports something real rather than nothing at all.
    for candidate in "$@"; do
        if [ -n "$candidate" ]; then printf '%s\n' "${candidate//\\//}"; return 0; fi
    done
    printf '%s\n' "$DEFAULT_SDK"
}

SDK="$(pick_sdk "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "${ANDROID_SDK:-}" "$DEFAULT_SDK")"
BT="$(newest "$SDK"/build-tools/*/)"
PLATFORM="$(newest "$SDK"/platforms/android-*)"
JAR="${PLATFORM%/}/android.jar"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$(newest "$SDK"/ndk/*/)}}"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/$NDK_HOST/bin"
STRIP="$NDK_BIN/llvm-strip$EXE"
JAVAC="${JAVAC:-${JAVA_HOME:+$JAVA_HOME/bin/javac}}"
JAVAC="${JAVAC:-javac}"
KEYTOOL="${KEYTOOL:-${JAVA_HOME:+$JAVA_HOME/bin/keytool}}"
KEYTOOL="${KEYTOOL:-keytool}"

for tool in "$SDK" "$BT" "$PLATFORM" "$NDK" "$STRIP" "$JAR"; do
    [ -e "$tool" ] || {
        echo "goats-android: missing $tool" >&2
        echo "  SDK=$SDK  BT=$BT  NDK=$NDK" >&2
        echo "  set ANDROID_SDK_ROOT and ANDROID_NDK_HOME (or install the NDK via sdkmanager)" >&2
        exit 1
    }
done

# The workspace patches raylib-sys to a path in this same build directory (see
# prepare-raylib-sys.py), so it has to exist before *any* cargo command -- which
# includes the one that produced the library checked just below.
"$PYTHON" "$HERE/prepare-raylib-sys.py"

[ -f "$SO" ] || {
    echo "goats-android: no $SO -- build the cdylib first:" >&2
    if [ "$PROFILE" = release ]; then
        echo "  cargo build --release -p goats-android --target aarch64-linux-android" >&2
    else
        echo "  cargo build -p goats-android --target aarch64-linux-android" >&2
    fi
    exit 1
}

command -v "$JAVAC" >/dev/null 2>&1 || {
    echo "goats-android: no javac on PATH -- a JDK is needed for the Activity" >&2
    exit 1
}

echo "goats-android: SDK=$SDK"
echo "goats-android: build-tools=${BT%/}  platform=${PLATFORM%/}"
echo "goats-android: NDK=$NDK  javac=$JAVAC"
echo "goats-android: profile=$PROFILE  so=$SO"

# Only this script's own products: `build/` also holds the prepared raylib-sys that
# the workspace patch points at, and that has to survive.
rm -rf "$OUT/stage" "$OUT/unaligned.apk" "$OUT/goats.apk"
mkdir -p "$OUT/stage/lib/arm64-v8a"

# A stripped copy: a `debug` build's `.so` carries line tables -- most of the library
# by size -- and all of them would cross the adb link on every install. A `release`
# build has none to lose, so this is a copy that strips nothing.
"$STRIP" --strip-debug -o "$OUT/stage/$LIB" "$SO"

# `GoatsActivity` and its input view. `-classpath` rather than `-bootclasspath`: the
# JDK's own `java.lang` is the same API as the platform's for what this file uses,
# and overriding the boot class path on a modern `javac` is the fragile half of the
# old recipe. `$JAR` is what supplies `android.app.NativeActivity` and the rest.
rm -rf "$OUT/stage/classes"
mkdir -p "$OUT/stage/classes"
"$JAVAC" -source 8 -target 8 -Xlint:-options \
    -classpath "$JAR" \
    -d "$OUT/stage/classes" \
    "$HERE"/java/dev/sdgoij/goats/*.java

# ...and the dex the framework actually loads, next to `lib/` in the archive.
"$BT/$D8" --lib "$JAR" --min-api 26 --output "$OUT/stage" \
    "$OUT/stage/classes/dev/sdgoij/goats/"*.class

# The APK, from the manifest alone: no resources. The manifest sets `hasCode="true"`,
# and the dex is added below beside the library.
"$BT/aapt2$EXE" link \
    -o "$OUT/unaligned.apk" \
    -I "$JAR" \
    --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 26 \
    --target-sdk-version 36

# The library and the dex have to be inside the archive before it is aligned and
# signed.
if command -v zip >/dev/null 2>&1; then
    (cd "$OUT/stage" && zip -q -r "$OUT/unaligned.apk" lib classes.dex)
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/jar" ]; then
    (cd "$OUT/stage" && "$JAVA_HOME/bin/jar" uf "$OUT/unaligned.apk" lib classes.dex)
else
    "$PYTHON" "$HERE/add_lib.py" "$OUT/unaligned.apk" "$OUT/stage/$LIB" "$LIB"
    "$PYTHON" "$HERE/add_lib.py" "$OUT/unaligned.apk" "$OUT/stage/classes.dex" "classes.dex"
fi

"$BT/zipalign$EXE" -p -f 4 "$OUT/unaligned.apk" "$APK"

# A debug keystore, made on the spot if there is none. A CI runner has no
# `~/.android`, and a debug key is a throwaway either way -- `apksigner` only has to
# prove the archive was not touched after it was built.
KS="${DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
if [ ! -f "$KS" ]; then
    echo "goats-android: making a debug keystore at $KS"
    mkdir -p "$(dirname "$KS")"
    "$KEYTOOL" -genkeypair -keystore "$KS" \
        -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" >/dev/null
fi

"$BT/$APKSIGNER" sign \
    --ks "$KS" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --ks-key-alias androiddebugkey \
    "$APK"

"$BT/$APKSIGNER" verify --print-certs "$APK" | head -4
ls -la "$APK"
echo
echo "install with: adb install -r $APK"
