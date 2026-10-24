#!/sbin/station/busybox sh
# Android (Quasar) mode on the mainline kernel, run by init as the first
# service (early-init). It replaces the vendor watchdogd:
#   - feeds the SoC watchdog while Android comes up;
#   - sets the mic ADCs up like the vendor's i2c_ma once /system is there
#     (the ADCs belong to the kernel driver now, i2c_ma cannot reach them);
#   - saves dmesg + logcat to the unused tail of misc (13 MiB) every 30 s;
#   - if Android has not finished booting after DEADLINE seconds, saves the
#     logs once more and stops feeding: the watchdog resets the Station
#     within 16 s and the next boot is the vendor kernel again.
B=/sbin/station/busybox
DEADLINE=600
MISC=/dev/block/mmcblk0p9
LOGSEEK=3328			# 4 KiB blocks: 13 MiB into misc (12 MiB = stage B log)
LOGMAX=1048576

i=0
while [ ! -e /dev/watchdog ] && [ $i -lt 600 ]; do $B sleep 0.1; i=$((i+1)); done
$B watchdog -F -t 4 -T 16 /dev/watchdog &
WD=$!

savelog() {
	{
		echo "STATION-ANDROID $1, up $($B cut -d' ' -f1 /proc/uptime) s, $(cat /proc/cmdline | $B sed 's/androidboot.serialno=[^ ]*/androidboot.serialno=<hidden>/')"
		[ -x /system/bin/getprop ] && /system/bin/getprop | $B grep -E 'boot|init\.svc|selinux|serialno' | $B sed 's/\(serialno\]: \[\)[^]]*/\1<hidden>/'
		echo "--- dmesg"
		$B dmesg | $B tail -c 300000
		echo "--- logcat"
		[ -x /system/bin/logcat ] && /system/bin/logcat -d -v time 2>/dev/null | $B tail -c 600000
		echo "--- end"
	} 2>&1 | $B head -c $LOGMAX > /dev/station-android.log
	$B dd if=/dev/station-android.log of=$MISC bs=4096 seek=$LOGSEEK conv=notrunc,fsync 2>/dev/null
}

mics_done=0
mics() {
	T=/system/bin/tinymix
	[ -x $T ] || return 1
	FLAT="32767 0 0 0 0"
	BQ="32546 32990 32546 32545 33210 $FLAT $FLAT $FLAT $FLAT"
	for k in 0 1 2 3 4; do
		p=ADC$k
		case $k in 0|1|2) g="40 40" ;; 3) g="40 1" ;; 4) g="1 1" ;; esac
		$T -D 2 "$p Left Input DIF_2L_3L Capture Switch" 1
		$T -D 2 "$p Right Input DIF_2R_3R Capture Switch" 1
		$T -D 2 "$p Left Input DIF_2L_3L Capture Volume" 1
		$T -D 2 "$p Right Input DIF_2R_3R Capture Volume" 1
		$T -D 2 "$p PGA Capture Volume" $g
		$T -D 2 "$p PGA Capture Switch" 1 1
		$T -D 2 "$p ADC Soft Stepping" 0
		$T -D 2 "$p ADC Processing Block" 1
		$T -D 2 "$p Left ADC Biquad Coefficients" $BQ
		$T -D 2 "$p Right ADC Biquad Coefficients" $BQ
	done > /dev/station-mics.log 2>&1
	return 0
}

t=0
while :; do
	$B sleep 10
	t=$((t + 10))
	[ $mics_done = 0 ] && mics && mics_done=1
	[ -x /system/bin/getprop ] && [ "$(/system/bin/getprop sys.boot_completed)" = 1 ] && break
	[ $((t % 30)) = 0 ] && savelog "booting, ${t} s"
	if [ $t -ge $DEADLINE ]; then
		savelog "TIMEOUT after ${t} s, letting the watchdog reset"
		kill -9 $WD
		exit 0
	fi
done

savelog "boot completed after ${t} s"
$B sleep 300
savelog "boot completed, +300 s"
wait $WD
