#!/bin/bash
# Static arm64 busybox and kexec for the initramfs, and strace for debugging,
# built from source.
#   usage: scripts/build-userspace.sh [jobs]    -> out/userspace/{busybox,kexec,strace}
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
B=$TOP/build/userspace; OUT=$TOP/out/userspace
J=${1:-$(nproc)}
BUSYBOX=1.37.0
KEXEC=2.0.32
STRACE=7.2
mkdir -p "$B" "$OUT"
cd "$B"
fetch() { [ -f "$2" ] || curl -fL --retry 3 -o "$2" "$1/$2"; }
fetch https://busybox.net/downloads "busybox-$BUSYBOX.tar.bz2"
fetch https://cdn.kernel.org/pub/linux/utils/kernel/kexec "kexec-tools-$KEXEC.tar.xz"
fetch "https://github.com/strace/strace/releases/download/v$STRACE" "strace-$STRACE.tar.xz"
sha256sum -c --quiet "$TOP/scripts/userspace.sha256"

rm -rf "busybox-$BUSYBOX" && tar -xf "busybox-$BUSYBOX.tar.bz2"
cd "busybox-$BUSYBOX"
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
# static; tc needs the CBQ uapi that newer kernel headers dropped; the SHA
# "hwaccel" code is x86 only
sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
	-e 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' \
	-e 's/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' .config
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig < /dev/null > /dev/null
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$J" busybox
aarch64-linux-gnu-strip -o "$OUT/busybox" busybox
cd "$B"

rm -rf "kexec-tools-$KEXEC" && tar -xf "kexec-tools-$KEXEC.tar.xz"
cd "kexec-tools-$KEXEC"
./configure -q --host=aarch64-linux-gnu --without-xen --without-lzma --without-zstd LDFLAGS=-static
make -s -j"$J"
aarch64-linux-gnu-strip -o "$OUT/kexec" build/sbin/kexec
cd "$B"

rm -rf "strace-$STRACE" && tar -xf "strace-$STRACE.tar.xz"
cd "strace-$STRACE"
./configure -q --host=aarch64-linux-gnu --enable-mpers=no --disable-gcc-Werror LDFLAGS=-static
make -s -j"$J"
aarch64-linux-gnu-strip -o "$OUT/strace" src/strace
cd "$OUT"
file busybox kexec strace
sha256sum busybox kexec strace > SHA256SUMS
