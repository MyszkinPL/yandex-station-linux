#!/bin/bash
# Android-mode user space pieces, built with the NDK for Android 6 (API 23):
#   out/android/lib64/libion.so, out/android/lib/libion.so
#   usage: scripts/build-android.sh       (NDK from $ANDROID_NDK_HOME or $ANDROID_NDK_LATEST_HOME)
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
NDK=${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}
[ -d "$NDK" ] || { echo "no NDK (set ANDROID_NDK_HOME)"; exit 1; }
BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
OUT=$TOP/out/android
API=23
CFLAGS="-O2 -Wall -Wextra -Werror -fPIC -fvisibility=default"
mkdir -p "$OUT/lib64" "$OUT/lib"

# same soname and entry points as the vendor libion, see the file header
"$BIN/aarch64-linux-android$API-clang" $CFLAGS -shared -Wl,-soname,libion.so \
	-o "$OUT/lib64/libion.so" "$TOP/android/libion/libion.c"
"$BIN/armv7a-linux-androideabi$API-clang" $CFLAGS -shared -Wl,-soname,libion.so \
	-o "$OUT/lib/libion.so" "$TOP/android/libion/libion.c"

# DRM/KMS hardware composer, in place of hwcomposer.tulip (SurfaceFlinger is 64-bit)
mkdir -p "$OUT/lib64/hw"
"$BIN/aarch64-linux-android$API-clang" $CFLAGS -Wno-unused-parameter -shared \
	-I "$TOP/android/include" -o "$OUT/lib64/hw/hwcomposer.drm.so" \
	"$TOP/android/hwcomposer/hwcomposer.c" -llog

for f in "$OUT/lib64/libion.so" "$OUT/lib/libion.so" "$OUT/lib64/hw/hwcomposer.drm.so"; do
	"$BIN/llvm-strip" --strip-unneeded "$f"
	echo "$f: $("$BIN/llvm-readelf" -d "$f" | grep -c NEEDED) needed, exports:" \
		"$("$BIN/llvm-nm" -D --defined-only "$f" | awk '$2 == "T" {print $3}' | sort | tr '\n' ' ')"
done
(cd "$OUT" && sha256sum lib64/libion.so lib/libion.so lib64/hw/hwcomposer.drm.so > SHA256SUMS)
