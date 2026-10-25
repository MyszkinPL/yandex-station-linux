#!/system/bin/sh
# Yandex Android hands the Station to our own system (the recovery partition,
# one-shot flag in the PMIC), so a power cut ends in ours too. Started from
# /system/etc/rc.local in the background (android/install-handoff.sh).
#
# On 2026-10-25 an earlier version rebooted Android in the middle of its boot:
# Android lost its Wi-Fi settings and the Station was off the network in both
# systems. So now Android is never left before it is settled, and it stays —
# a net that cannot loop — whenever handing over would be a guess:
# - not before sys.boot_completed and HOLD_NET seconds of Wi-Fi with an
#   address, unbroken (Android has saved its networks; ours reads the same
#   ones). Without a network it waits as long as it takes: the router may
#   come back later than the Station after a power cut;
# - the recovery partition must hold the image we put there, by its sha256
#   (station/recovery.sha256: "<sha256> <size>"); anything else, a stock
#   recovery after a factory reset say, is never booted;
# - the log our init keeps in the tail of misc must say its last boot came up:
#   STATION-MAINLINE-HANDOFF          handed over, and it never started
#   STATION-MAINLINE-ALIVE-B1 (early) it started and stopped before the network
#   STATION-MAINLINE-STAY             asked to stay (the Alice key held, station-android)
#   anything else / nothing           not ours
#   and only ALIVE-B1 with any other result hands over;
# - /data/local/station/stay exists.

S=/data/local/station
B=$S/busybox
MISC=/dev/block/mmcblk0p9
REC=/dev/block/mmcblk0p10
LOG_SEEK=3072                     # 4 KiB blocks: 12 MiB into misc
PMIC=/sys/bus/platform/devices/axp81x_board/axp81x_reg
OUT=$S/handoff.log
HOLD_NET=120

say() { echo "$($B date '+%F %T') $*" >> $OUT; }

[ -x $B ] || exit 0
say "started"
i=0
until [ "$(getprop sys.boot_completed)" = 1 ]; do
	sleep 5; i=$((i + 5))
	[ $i -ge 900 ] && { say "Android not booted after 15 min: staying"; exit 0; }
done
say "Android booted, waiting for ${HOLD_NET}s of Wi-Fi"
held=0
while [ $held -lt $HOLD_NET ]; do
	sleep 5
	if $B ip -4 addr show wlan0 2>/dev/null | $B grep -q "inet "; then
		held=$((held + 5))
	else
		held=0
	fi
done

[ -e $S/stay ] && { say "stay file: staying"; exit 0; }
head=$($B dd if=$MISC bs=4096 skip=$LOG_SEEK count=1 2>/dev/null | $B head -n1 | $B tr -d '\000')
case "$head" in
"STATION-MAINLINE-ALIVE-B1 (early)"*) say "last boot stopped early: staying"; exit 0 ;;
STATION-MAINLINE-ALIVE-B1*) ;;
*) say "log says '$head': staying"; exit 0 ;;
esac
set -- $(cat $S/recovery.sha256 2>/dev/null)
want=$1 size=$2
[ ${#want} = 64 ] && [ -n "$size" ] || { say "no recovery.sha256: staying"; exit 0; }
got=$($B head -c "$size" $REC | $B sha256sum | $B cut -c1-64)
[ "$got" = "$want" ] || { say "recovery is not ours ($got): staying"; exit 0; }

echo 0f > $PMIC
[ "$(cat $PMIC)" = 'REG[f]=e' ] || { say "PMIC flag not 0x0E ($(cat $PMIC)): staying"; exit 0; }
echo 0f10 > $PMIC
echo 0f > $PMIC
[ "$(cat $PMIC)" = 'REG[f]=10' ] || { say "PMIC flag not set ($(cat $PMIC)): staying"; exit 0; }
# the hand-over is marked: if ours does not start, the next Android stays
printf 'STATION-MAINLINE-HANDOFF\n' | $B dd of=$MISC bs=4096 seek=$LOG_SEEK conv=notrunc,sync 2>/dev/null
say "last boot '$head': handing over"
sync
/system/bin/reboot
