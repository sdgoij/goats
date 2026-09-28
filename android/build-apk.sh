#!/usr/bin/env bash
#
# P0 packaging: a NativeActivity APK around the client's cdylib, by hand -- now
# with the Java that P2 needs for the keyboard, the clipboard and the insets.
#
# Gradle is not used on purpose: the artifact is one `.so`, one `classes.dex`, a
# manifest and no resources, and `javac` + `d8` + `aapt2` + `zipalign` + `apksigner`
# are all in the SDK and the JDK that are already installed. A Gradle project would
# add a build tool that has to be downloaded and a plugin that has to match it, for
# nothing this build does (ANDROID.md D6).
#
# Run it after `cargo build -p goats-android --target aarch64-linux-android`
# (see ANDROID.md's "The build, concretely" for the environment that needs).
set -euo pipefail

SDK="${ANDROID_SDK:-C:/Users/T/AppData/Local/Android/Sdk}"
BT="$SDK/build-tools/36.0.0"
JAR="$SDK/platforms/android-36.1/android.jar"
NDK="${ANDROID_NDK_HOME:-C:/Users/T/AppData/Local/Android/android-ndk-r30}"
STRIP="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe"
JAVAC="${JAVAC:-javac}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SO="$ROOT/target/aarch64-linux-android/debug/libgoats_android.so"
OUT="$HERE/build"
APK="$OUT/goats.apk"
LIB="lib/arm64-v8a/libgoats_android.so"

# The workspace patches raylib-sys to a path in this same build directory (see
# prepare-raylib-sys.py), so it has to exist before *any* cargo command -- which
# includes the one that produced the library checked just below.
python "$HERE/prepare-raylib-sys.py"

[ -f "$SO" ] || {
    echo "goats-android: no $SO -- build the cdylib first" >&2
    exit 1
}

command -v "$JAVAC" >/dev/null || {
    echo "goats-android: no javac on PATH -- a JDK is needed for the Activity" >&2
    exit 1
}

# Only this script's own products: `build/` also holds the prepared raylib-sys
# that the workspace patch points at, and that has to survive.
rm -rf "$OUT/stage" "$OUT/unaligned.apk" "$OUT/goats.apk"
mkdir -p "$OUT/stage/lib/arm64-v8a"

# Debug info is most of the library and all of it would have to cross the adb
# link on every install, so the APK gets a stripped copy.
"$STRIP" --strip-debug -o "$OUT/stage/$LIB" "$SO"

# `GoatsActivity` and its input view. `-classpath` rather than `-bootclasspath`:
# the JDK's own `java.lang` is the same API as the platform's for what this file
# uses, and overriding the boot class path on a JDK 17 `javac` is the fragile half
# of the old recipe. `$JAR` is what supplies `android.app.NativeActivity` and the
# rest.
rm -rf "$OUT/stage/classes"
mkdir -p "$OUT/stage/classes"
"$JAVAC" -source 8 -target 8 -Xlint:-options \
    -classpath "$JAR" \
    -d "$OUT/stage/classes" \
    "$HERE"/java/dev/sdgoij/goats/*.java

# ...and the dex the framework actually loads, next to `lib/` in the archive.
"$BT/d8.bat" --lib "$JAR" --min-api 26 --output "$OUT/stage" \
    "$OUT/stage/classes/dev/sdgoij/goats/"*.class

# The APK, from the manifest alone: no resources. The manifest sets
# `hasCode="true"`, and the dex is added below beside the library.
"$BT/aapt2.exe" link \
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
    python "$HERE/add_lib.py" "$OUT/unaligned.apk" "$OUT/stage/$LIB" "$LIB"
    python "$HERE/add_lib.py" "$OUT/unaligned.apk" "$OUT/stage/classes.dex" "classes.dex"
fi

"$BT/zipalign.exe" -p -f 4 "$OUT/unaligned.apk" "$APK"

KS="${DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
"$BT/apksigner.bat" sign \
    --ks "$KS" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --ks-key-alias androiddebugkey \
    "$APK"

"$BT/apksigner.bat" verify --print-certs "$APK" | head -4
ls -la "$APK"
echo
echo "install with: adb install -r $APK"
