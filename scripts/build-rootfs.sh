#!/bin/bash
# The Station's root filesystem, built from Debian packages (rootfs/packages)
# so that it is the same every time and does not depend on a hand-made copy:
#   sudo scripts/build-rootfs.sh   -> out/rootfs-arm64.tar.gz (+ .sha256, rootfs-VERSION)
# Needs mmdebstrap and qemu-user-static (binfmt) to run arm64 maintainer
# scripts on an x86 host. The archive unpacks into a directory that init uses
# as the read-only lower layer; state lives elsewhere (/station/persist).
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
cd "$TOP"
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
mkdir -p out
pkgs=$(grep -v '^\s*#' rootfs/packages | grep -v '^\s*$' | paste -sd, -)

mmdebstrap --mode=root --variant=minbase --arch=arm64 \
	--include="$pkgs" \
	--aptopt='APT::Install-Recommends "false"' \
	--dpkgopt='path-exclude=/usr/share/man/*' \
	--dpkgopt='path-exclude=/usr/share/info/*' \
	--dpkgopt='path-exclude=/usr/share/doc/*' \
	--dpkgopt='path-include=/usr/share/doc/*/copyright' \
	--dpkgopt='path-exclude=/usr/share/locale/*' \
	--dpkgopt='path-include=/usr/share/locale/locale.alias' \
	--customize-hook='echo station > "$1/etc/hostname"' \
	--customize-hook='rm -rf "$1"/var/lib/apt/lists/* "$1"/var/cache/apt/*.bin "$1"/var/log/*.log' \
	--customize-hook='mkdir -p "$1/station" "$1/opt/station"' \
	"$SUITE" out/rootfs-arm64.tar "$MIRROR"

gzip -9 -f out/rootfs-arm64.tar
(cd out && sha256sum rootfs-arm64.tar.gz > rootfs-arm64.tar.gz.sha256)
echo "$SUITE $(git rev-parse --short HEAD 2>/dev/null || echo local) $(date -u +%Y-%m-%d)" > out/rootfs-VERSION
echo "out/rootfs-arm64.tar.gz: $(cat out/rootfs-VERSION), $(stat -c %s out/rootfs-arm64.tar.gz) bytes"
