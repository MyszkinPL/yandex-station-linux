#!/bin/bash
# Mali-400 (utgard) kernel driver from ARM's release, for the vendor Android
# userspace (libGLES_mali). Builds against the tree scripts/build-kernel.sh left.
#   usage: scripts/build-mali.sh [jobs]          -> out/mali.ko
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
B=$TOP/build; O=$B/obj; OUT=$TOP/out
J=${1:-$(nproc)}
R=$(cat "$TOP/gpu/mali/VERSION")
T=DX910-SW-99002-$R.tgz
[ -f "$O/.config" ] || { echo "build the kernel first (scripts/build-kernel.sh)"; exit 1; }
cd "$B"
[ -f "$T" ] || curl -fL --retry 3 -o "$T" "https://developer.arm.com/-/media/Files/downloads/mali-drivers/kernel/mali-utgard-gpu/$T"
sha256sum -c --quiet "$TOP/gpu/mali/source.sha256"
rm -rf mali && mkdir mali && tar -C mali --strip-components=2 -xzf "$T"   # DX910-SW-99002-$R/driver/
# ten files of the release mix CRLF and LF lines; the patches are LF
find mali -type f \( -name '*.[ch]' -o -name Makefile -o -name Kbuild \) -exec sed -i 's/\r$//' {} +
while read -r p; do
	case "$p" in ''|'#'*) continue ;; esac
	patch -d mali -p1 -s --no-backup-if-mismatch < "$TOP/gpu/mali/patches/$p" || { echo "FAILED: $p"; exit 1; }
	echo "applied $p"
done < "$TOP/gpu/mali/patches/series"

# USING_DT: the GPU node comes from the device tree (allwinner,sun50i-a64-mali);
# no UMP, no profiling; DVFS stays with the vendor SCP firmware
make -C mali/src/devicedrv/mali -j"$J" KDIR="$O" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
	USING_UMP=0 BUILD=release USING_PROFILING=0 USING_DT=1 MALI_PLATFORM=sunxi \
	USING_DVFS=0 USING_DEVFREQ=0
aarch64-linux-gnu-strip --strip-debug -o "$OUT/mali.ko" mali/src/devicedrv/mali/mali.ko
modinfo "$OUT/mali.ko" | grep -E '^(version|vermagic|depends):'
(cd "$OUT" && sha256sum mali.ko >> SHA256SUMS)
