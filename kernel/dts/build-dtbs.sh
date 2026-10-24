#!/bin/bash
# Build the Station DTBs from one DTS with WF2_* switches.
# usage: build-dtbs.sh <kernel source> <out dir> [dtc]
set -eu
K=$(realpath "$1"); OUT=$(realpath -m "$2"); DTC=${3:-$K/scripts/dtc/dtc}
SRC=$(dirname "$(realpath "$0")")/sun50i-a64-yandex-station.dts
mkdir -p "$OUT"
COMMON="-DWF2_SMP=1 -DWF2_RTC=1 -DWF2_THERMAL=1 -DWF2_CPUFREQ=1 -DWF2_WIFI=0 -DWF2_WIFI_ID=1 -DWF2_PMIC=1"
variants=(
	# Linux mode (stage B): serdev Bluetooth, LED ring and keys, audio
	"station|$COMMON -DWF2_BT=2 -DWF2_LEDS_KEYS=1 -DWF2_AUDIO=1"
	# vendor Android / Quasar on this kernel: tty Bluetooth, LEDs/keys left
	# to Quasar, PMIC node off, /firmware/android
	"station-android|$COMMON -DWF2_BT=1 -DWF2_LEDS_KEYS=0 -DWF2_AUDIO=1 -DWF2_PMIC=0 -DWF2_QUASAR=1"
)
cd "$OUT"
for v in "${variants[@]}"; do
	n=${v%%|*}
	# shellcheck disable=SC2086
	cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P \
		-I "$K/arch/arm64/boot/dts/allwinner" -I "$K/arch/arm64/boot/dts" \
		-I "$K/include" -I "$K/scripts/dtc/include-prefixes" \
		${v#*|} "$SRC" -o "$n.pp.dts"
	"$DTC" -q -I dts -O dtb -o "$n.dtb" "$n.pp.dts"
	rm "$n.pp.dts"
	grep -aq 'watchdog.stop_on_reboot=0' "$n.dtb" || { echo "FAIL $n: no stop_on_reboot=0"; exit 1; }
	! grep -aq 'maxcpus=1' "$n.dtb" || { echo "FAIL $n: maxcpus=1"; exit 1; }
	echo "$n.dtb $(stat -c %s "$n.dtb") bytes"
done
