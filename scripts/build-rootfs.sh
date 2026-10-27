#!/bin/bash
# The Station's root filesystem, built from Debian packages (rootfs/packages)
# so that it is the same every time and does not depend on a hand-made copy:
#   sudo scripts/build-rootfs.sh         -> out/rootfs-arm64.tar.gz (+ .sha256, rootfs-VERSION)
#   sudo scripts/build-rootfs.sh plain   -> out/rootfs-plain-arm64.tar.gz: plain Debian for
#        the community (rootfs/plain: its packages, and files laid over it), apt pointed at
#        the live Debian mirrors, none of our services
# Needs mmdebstrap and qemu-user-static (binfmt) to run arm64 maintainer
# scripts on an x86 host. The archive unpacks into a directory that init uses
# as the read-only lower layer; state lives elsewhere (/station/persist).
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
cd "$TOP"
SUITE=${SUITE:-trixie}
# Debian as it was at one moment (rootfs/snapshot), not as it is today: a
# rebuild gives the same packages, and moving to newer ones is a commit of
# its own — the services read some of these programs' output (FOUNDATION.md)
SNAPSHOT=$(grep -v '^\s*#' rootfs/snapshot | head -n1)
MIRROR=${MIRROR:-http://snapshot.debian.org/archive/debian/$SNAPSHOT}
mkdir -p out

VARIANT=${1:-}
case "$VARIANT" in
"")
	LIST=rootfs/packages NAME=rootfs
	EXTRA=()
	;;
plain)
	LIST=rootfs/plain/packages NAME=rootfs-plain
	EXTRA=(
		# its own files, owned by root whatever the checkout's owner
		--customize-hook="tar -C '$TOP/rootfs/plain/files' --owner=0 --group=0 -c . | tar -C \"\$1\" -x"
		--customize-hook='chmod 755 "$1/etc/station/start" "$1/usr/local/sbin/station-wifi"'
		# apt from the live mirrors (debian.sources), not the snapshot it was built from
		--customize-hook='rm -f "$1/etc/apt/sources.list"'
	)
	;;
*)
	echo "usage: build-rootfs.sh [plain]" >&2
	exit 2
	;;
esac
pkgs=$(grep -v '^\s*#' $LIST | grep -v '^\s*$' | paste -sd, -)
VERSION="$SUITE@$SNAPSHOT${VARIANT:+ $VARIANT} $(git rev-parse --short HEAD 2>/dev/null || echo local) $(date -u +%Y-%m-%d)"

mmdebstrap --mode=root --variant=minbase --arch=arm64 \
	--include="$pkgs" \
	--aptopt='APT::Install-Recommends "false"' \
	--aptopt='Acquire::Check-Valid-Until "false"' \
	--dpkgopt='path-exclude=/usr/share/man/*' \
	--dpkgopt='path-exclude=/usr/share/info/*' \
	--dpkgopt='path-exclude=/usr/share/doc/*' \
	--dpkgopt='path-include=/usr/share/doc/*/copyright' \
	--dpkgopt='path-exclude=/usr/share/locale/*' \
	--dpkgopt='path-include=/usr/share/locale/locale.alias' \
	--customize-hook='echo station > "$1/etc/hostname"' \
	--customize-hook="echo '$VERSION' > \"\$1/etc/station-rootfs\"" \
	--customize-hook='rm -rf "$1"/var/lib/apt/lists/* "$1"/var/cache/apt/*.bin "$1"/var/log/*.log' \
	--customize-hook='mkdir -p "$1/station" "$1/opt/station"' \
	"${EXTRA[@]}" \
	"$SUITE" out/$NAME-arm64.tar "$MIRROR"

gzip -9 -f out/$NAME-arm64.tar
(cd out && sha256sum $NAME-arm64.tar.gz > $NAME-arm64.tar.gz.sha256)
echo "$VERSION" > out/$NAME-VERSION
echo "out/$NAME-arm64.tar.gz: $(cat out/$NAME-VERSION), $(stat -c %s out/$NAME-arm64.tar.gz) bytes"
