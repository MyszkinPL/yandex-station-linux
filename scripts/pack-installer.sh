#!/bin/bash
# The Debian installer as one file for the community: station-debian.run is a
# small sh stub, our static busybox and installer/station-debian.sh, with the
# release's files pinned in it by sha256. It runs under Android's own sh
# (sh station-debian.run), which knows nothing but the stub: the stub takes
# busybox out, checks it and hands over to the installer under busybox's sh.
#   scripts/pack-installer.sh <tag> <dir with the release's files> <busybox>
#   -> <dir>/station-debian.run
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?tag}; D=${2:?dir}; BUSYBOX=${3:?busybox}
REPO=${GITHUB_REPOSITORY:-MyszkinPL/yandex-station-linux}
IMG=recovery-station.img BOOT_IMG=boot-station.img ROOTFS=rootfs-plain-arm64.tar.gz
for f in $IMG $BOOT_IMG $ROOTFS; do [ -s "$D/$f" ] || { echo "no $D/$f" >&2; exit 1; }; done
sha() { sha256sum "$1" | cut -d' ' -f1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# the installer, with what it installs pinned and Android's hand-off inside
sed -e "s|@VERSION@|$TAG|" -e "s|@URL@|https://github.com/$REPO/releases/download/$TAG|" \
	-e "s|@IMG@|$IMG|" -e "s|@IMG_SHA@|$(sha "$D/$IMG")|" -e "s|@IMG_SIZE@|$(stat -c %s "$D/$IMG")|" \
	-e "s|@BOOT_IMG@|$BOOT_IMG|" -e "s|@BOOT_SHA@|$(sha "$D/$BOOT_IMG")|" -e "s|@BOOT_SIZE@|$(stat -c %s "$D/$BOOT_IMG")|" 	-e "s|@ROOTFS@|$ROOTFS|" -e "s|@ROOTFS_SHA@|$(sha "$D/$ROOTFS")|" "$TOP/installer/station-debian.sh" |
	awk -v f="$TOP/android/station-handoff.sh" '$0 == "@HANDOFF@" { while ((getline l < f) > 0) print l; next } { print }' > "$W/installer.sh"
! grep -n '@[A-Z_]*@' "$W/installer.sh" || { echo "placeholders left" >&2; exit 1; }
grep -q '^HANDOFF_EOF$' "$W/installer.sh" && [ "$(grep -c '^HANDOFF_EOF$' "$W/installer.sh")" = 1 ]
sh -n "$W/installer.sh"
# the boot partition is 16 MiB
[ $(stat -c %s "$D/$BOOT_IMG") -le 16777216 ] || { echo "$BOOT_IMG does not fit the boot partition" >&2; exit 1; }

# busybox in whole 4 KiB blocks (an ELF does not mind the zeros after it)
cp "$BUSYBOX" "$W/busybox"
truncate -s $(( ($(stat -c %s "$W/busybox") + 4095) / 4096 * 4096 )) "$W/busybox"
BB_BLOCKS=$(( $(stat -c %s "$W/busybox") / 4096 ))
STUB_BLOCKS=1

# the stub: Android's dd takes busybox out, busybox checks itself and the rest
cat > "$W/stub" <<EOF
#!/system/bin/sh
# Debian for the Yandex Station 1, release $TAG: github.com/$REPO
# On the Station, in Android, as root:   sh station-debian.run   (--help: what else)
S=/data/local/station
mkdir -p \$S/bin || exit 1
dd if="\$0" of=\$S/bin/busybox.new bs=4096 skip=$STUB_BLOCKS count=$BB_BLOCKS 2>/dev/null
chmod 755 \$S/bin/busybox.new
B=\$S/bin/busybox.new
[ "\$(\$B sha256sum \$B 2>/dev/null | \$B cut -d' ' -f1)" = $(sha "$W/busybox") ] ||
	{ echo "station-debian.run: the file is damaged (busybox), download it again"; exit 1; }
mv \$B \$S/bin/busybox; B=\$S/bin/busybox
\$B --install -s \$S/bin 2>/dev/null
\$B dd if="\$0" bs=4096 skip=$((STUB_BLOCKS + BB_BLOCKS)) 2>/dev/null > \$S/bin/station-debian.sh
[ "\$(\$B sha256sum \$S/bin/station-debian.sh | \$B cut -d' ' -f1)" = $(sha "$W/installer.sh") ] ||
	{ echo "station-debian.run: the file is damaged (installer), download it again"; exit 1; }
BB=\$B exec \$B sh \$S/bin/station-debian.sh "\$@"
EOF
[ $(stat -c %s "$W/stub") -lt 4096 ]
# padded with newlines to its block: the shell stops at exec, never reads on
head -c $((4096 - $(stat -c %s "$W/stub"))) /dev/zero | tr '\0' '\n' >> "$W/stub"

cat "$W/stub" "$W/busybox" "$W/installer.sh" > "$D/station-debian.run"
echo "$D/station-debian.run: $(stat -c %s "$D/station-debian.run") bytes, $TAG"
