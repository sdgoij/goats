#!/usr/bin/env bash
#
# P0 packaging: a NativeActivity APK around the client's cdylib, by hand.
#
# Gradle lands with the Java Activity in P2 (ANDROID.md D6); P0 only needs a
# picture on a screen, and aapt2 + a zip + zipalign + apksigner is that with
# nothing to install. All of this is one-off scaffolding.
#
# Run it after `cargo build -p goats-android --target aarch64-linux-android`
# (see ANDROID.md's "The build, concretely" for the environment that needs).
set -euo pipefail

SDK="${ANDROID_SDK:-C:/Users/T/AppData/Local/Android/Sdk}"
BT="$SDK/build-tools/36.0.0"
JAR="$SDK/platforms/android-36.1/android.jar"
NDK="${ANDROID_NDK_HOME:-C:/Users/T/AppData/Local/Android/android-ndk-r30}"
STRIP="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe"

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

# Only this script's own products: `build/` also holds the prepared raylib-sys
# that the workspace patch points at, and that has to survive.
rm -rf "$OUT/stage" "$OUT/unaligned.apk" "$OUT/goats.apk"
mkdir -p "$OUT/stage/lib/arm64-v8a"

# Debug info is most of the library and all of it would have to cross the adb
# link on every install, so the APK gets a stripped copy.
"$STRIP" --strip-debug -o "$OUT/stage/$LIB" "$SO"

# The APK, from the manifest alone: no resources, no dex (`hasCode="false"`).
"$BT/aapt2.exe" link \
    -o "$OUT/unaligned.apk" \
    -I "$JAR" \
    --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 26 \
    --target-sdk-version 36

# The library has to be inside the archive before it is aligned and signed.
if command -v zip >/dev/null 2>&1; then
    (cd "$OUT/stage" && zip -q -r "$OUT/unaligned.apk" lib)
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/jar" ]; then
    "$JAVA_HOME/bin/jar" uf "$OUT/unaligned.apk" -C "$OUT/stage" lib
else
    python "$HERE/add_lib.py" "$OUT/unaligned.apk" "$OUT/stage/$LIB" "$LIB"
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
