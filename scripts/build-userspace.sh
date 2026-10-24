#!/bin/bash
# Static arm64 busybox and kexec for the initramfs, built from source.
#   usage: scripts/build-userspace.sh [jobs]    -> out/userspace/{busybox,kexec}
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
B=$TOP/build/userspace; OUT=$TOP/out/userspace
J=${1:-$(nproc)}
BUSYBOX=1.37.0
KEXEC=2.0.32
mkdir -p "$B" "$OUT"
cd "$B"
fetch() { [ -f "$2" ] || curl -fL --retry 3 -o "$2" "$1/$2"; }
fetch https://busybox.net/downloads "busybox-$BUSYBOX.tar.bz2"
fetch https://cdn.kernel.org/pub/linux/utils/kernel/kexec "kexec-tools-$KEXEC.tar.xz"
sha256sum -c --quiet "$TOP/scripts/userspace.sha256"

rm -rf "busybox-$BUSYBOX" && tar -xf "busybox-$BUSYBOX.tar.bz2"
cd "busybox-$BUSYBOX"
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
# static; tc needs the CBQ uapi that newer kernel headers dropped
sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig < /dev/null > /dev/null
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$J" busybox
aarch64-linux-gnu-strip -o "$OUT/busybox" busybox
cd "$B"

rm -rf "kexec-tools-$KEXEC" && tar -xf "kexec-tools-$KEXEC.tar.xz"
cd "kexec-tools-$KEXEC"
./configure -q --host=aarch64-linux-gnu --without-xen --without-lzma --without-zstd LDFLAGS=-static
make -s -j"$J"
aarch64-linux-gnu-strip -o "$OUT/kexec" build/sbin/kexec
cd "$OUT"
file busybox kexec
sha256sum busybox kexec > SHA256SUMS
