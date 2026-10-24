#!/sbin/station/busybox sh
# First process of the Android (Quasar) mode on the mainline kernel
# (rdinit=/station-init): start a mirror of the kernel log into the unused
# tail of misc (14 MiB), so a failure before Android's own services run can
# still be read after the Station is back on the vendor kernel; then hand
# PID 1 to Android's init. The mirror works in a tmpfs of its own (/.slog):
# Android's init remounts the ramdisk root read-only. It stops after 15 minutes.
B=/sbin/station/busybox
$B mount -t sysfs sysfs /sys
i=0
while [ ! -e /sys/class/block/mmcblk0p9/dev ] && [ $i -lt 50 ]; do $B sleep 0.1; i=$((i+1)); done
dev=$($B cat /sys/class/block/mmcblk0p9/dev 2>/dev/null)
$B umount /sys
if [ -n "$dev" ]; then
	$B mkdir -p /.slog
	$B mount -t tmpfs -o size=4m,mode=0700 tmpfs /.slog
	$B mknod /.slog/misc b "${dev%%:*}" "${dev##*:}"
	(
		n=0
		while [ $n -lt 1100 ]; do
			{ echo "STATION-KLOG $n"; $B dmesg; } 2>/dev/null | $B head -c 1048576 > /.slog/k
			$B dd if=/.slog/k of=/.slog/misc bs=4096 seek=3584 conv=notrunc,fsync 2>/dev/null
			# every 50 ms for the first 10 s: a failing init reboots fast
			if [ $n -lt 200 ]; then $B sleep 0.05; else $B sleep 1; fi
			n=$((n + 1))
		done
	) &
fi

# station.debug: run Android's init in its own PID namespace, where its
# reboot() ends the namespace instead of resetting the SoC; then save the
# whole kernel log and reset ourselves.
$B mount -t proc proc /proc
debug=$($B grep -c station.debug /proc/cmdline)
$B umount /proc
if [ "$debug" = 1 ] && [ -n "$dev" ]; then
	$B unshare -p -f /init
	rc=$?
	$B sleep 1
	{ echo "STATION-KLOG final: Android init (PID namespace) ended, rc=$rc"; $B dmesg; } 2>/dev/null |
		$B tail -c 1048000 > /.slog/k
	$B dd if=/.slog/k of=/.slog/misc bs=4096 seek=3584 conv=notrunc,fsync 2>/dev/null
	$B sync
	$B reboot -f
fi
exec /init
