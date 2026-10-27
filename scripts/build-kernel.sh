#!/bin/bash
# Build the Station kernel: linux-$(cat kernel/VERSION) + kernel/series, our
# config and DTBs, plus the boot shim. Used by CI; runs the same on any
# Debian/Ubuntu machine with gcc-aarch64-linux-gnu.
#   usage: scripts/build-kernel.sh [jobs]      (tarball in build/ or downloaded)
# Output in out/: Image, dtb/*.dtb, modules.tar.gz, shim.bin, config,
# System.map, kernel.release, SHA256SUMS.
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
V=$(cat "$TOP/kernel/VERSION")
B=$TOP/build; S=$B/linux-$V; O=$B/obj; OUT=$TOP/out
J=${1:-$(nproc)}
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER=station KBUILD_BUILD_HOST=station-linux
CC="aarch64-linux-gnu-gcc"
command -v ccache >/dev/null && CC="ccache $CC"
mkdir -p "$B" "$OUT"

# --- source ---
T=$B/linux-$V.tar.xz
[ -f "$T" ] || curl -fL --retry 3 -o "$T" "https://cdn.kernel.org/pub/linux/kernel/v${V%%.*}.x/linux-$V.tar.xz"
(cd "$B" && sha256sum -c --quiet "$TOP/kernel/linux.sha256")
rm -rf "$S"
tar -C "$B" -xf "$T"
while read -r p; do
	case "$p" in ''|'#'*) continue ;; esac
	patch -d "$S" -p1 -s --no-backup-if-mismatch < "$TOP/kernel/patches/$p" || { echo "FAILED: $p"; exit 1; }
	echo "applied $p"
done < "$TOP/kernel/series"
cp "$TOP/kernel/dts/sun50i-a64-yandex-station.dts" "$S/arch/arm64/boot/dts/allwinner/"
echo 'dtb-$(CONFIG_ARCH_SUNXI) += sun50i-a64-yandex-station.dtb' >> "$S/arch/arm64/boot/dts/allwinner/Makefile"

# --- config ---
mkdir -p "$O"
cp "$TOP/kernel/station.config" "$O/.config"
make -s -C "$S" O="$O" CC="$CC" olddefconfig
# Options of station.config that olddefconfig dropped: an error when the
# symbol still exists (a dependency is missing), only a note when this
# kernel no longer has it (renamed or removed upstream: review on a bump).
symbols=$(find "$S" -name 'Kconfig*' -exec grep -hoE '^\s*(menu)?config\s+\w+' {} + | awk '{print $2}' | sort -u)
lost=""; gone=""
while IFS= read -r l; do
	grep -qxF "$l" "$O/.config" && continue
	sym=${l%%=*}; sym=${sym#CONFIG_}
	if echo "$symbols" | grep -qxF "$sym"; then lost="$lost  $l"$'\n'; else gone="$gone $sym"; fi
done < <(grep '^CONFIG_.*=[ym]$' "$TOP/kernel/station.config")
[ -z "$gone" ] || echo "note: no longer in this kernel:$gone"
[ -z "$lost" ] || { echo "options lost by olddefconfig:"; printf '%s' "$lost"; exit 1; }
# the same config, minimal: only what differs from the kernel's defaults
make -s -C "$S" O="$O" savedefconfig
cp "$O/defconfig" "$OUT/defconfig"

# --- build ---
make -s -k -C "$S" O="$O" CC="$CC" -j"$J" Image modules scripts_dtc
rm -rf "$B/modroot"
make -s -C "$S" O="$O" INSTALL_MOD_PATH="$B/modroot" INSTALL_MOD_STRIP=1 modules_install
tar -C "$B/modroot" --owner=0 --group=0 --sort=name --mtime=@0 -czf "$OUT/modules.tar.gz" lib
# For the initramfs: the drivers whose firmware init copies from the
# Station's own Android (Wi-Fi, the amplifiers, Bluetooth), with what they
# depend on and brcmfmac's vendor parts (it asks for those by name), and a
# modules.dep of their own.
KREL=$(cat "$O/include/config/kernel.release")
M=$B/modroot/lib/modules/$KREL
IM=$OUT/initramfs-modules
rm -rf "$IM"; mkdir -p "$IM/lib/modules/$KREL"
# station-load: the order init loads them in, what each depends on first
# (busybox's modprobe left the dependencies out on the Station)
{
	for n in brcmfmac snd-soc-tas571x hci_uart; do
		modprobe --show-depends -d "$B/modroot" -S "$KREL" "$n" | awk '$1 == "insmod" { print $2 }'
	done
	find "$M/kernel/drivers/net/wireless/broadcom" -name '*.ko' | sort
} | awk '!seen[$0]++' | while read -r ko; do
	rel=${ko#"$M"/}
	mkdir -p "$IM/lib/modules/$KREL/$(dirname "$rel")"
	cp "$ko" "$IM/lib/modules/$KREL/$rel"
	echo "$rel"
done > "$IM/station-load"
mv "$IM/station-load" "$IM/lib/modules/$KREL/station-load"
cp "$M"/modules.builtin* "$M"/modules.order "$IM/lib/modules/$KREL/"
depmod -b "$IM" "$KREL"
echo "initramfs modules, in load order:"; cat "$IM/lib/modules/$KREL/station-load"
echo "initramfs modules: $(find "$IM" -name '*.ko' | sed 's|.*/||' | tr '\n' ' ')"
"$TOP/kernel/dts/build-dtbs.sh" "$S" "$OUT/dtb" "$O/scripts/dtc/dtc"

# --- boot shim (boot/pack.py puts DTB, Image and initramfs behind it) ---
aarch64-linux-gnu-gcc -c -o "$B/shim.o" "$TOP/boot/shim.S"
aarch64-linux-gnu-ld -Ttext=0x40080000 -o "$B/shim.elf" "$B/shim.o"
aarch64-linux-gnu-objcopy -O binary "$B/shim.elf" "$OUT/shim.bin"

cp "$O/arch/arm64/boot/Image" "$O/System.map" "$OUT/"
cp "$O/.config" "$OUT/config"
cat "$O/include/config/kernel.release" > "$OUT/kernel.release"
(cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)
echo "kernel $(cat "$OUT/kernel.release"), modules: $(find "$B/modroot" -name '*.ko' | wc -l)"
