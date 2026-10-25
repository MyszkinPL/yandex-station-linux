#!/system/bin/sh
# Put station-handoff.sh into Yandex Android and start it from rc.local (in
# the background: it waits for Android to settle by itself).
# Runs IN Android as root with full capabilities (SSH from rc.local's
# dropbear, or the boot-root telnet):
#   sh install-handoff.sh /path/to/station-handoff.sh <recovery sha256> <size>
# The sha256 and size are those of the image in the recovery partition: the
# hand-over boots nothing else.
# Undo: rm /data/local/station/handoff.sh (rc.local's line then does nothing),
# or touch /data/local/station/stay.
set -e
src=${1:?usage: install-handoff.sh station-handoff.sh <sha256> <size>}
sha=${2:?recovery sha256}
size=${3:?recovery size}
S=/data/local/station
B=$S/busybox
[ -x $B ] || { echo "no $B"; exit 1; }
cp "$src" $S/handoff.sh
chmod 755 $S/handoff.sh
echo "$sha $size" > $S/recovery.sha256
RC=/system/etc/rc.local
line='( setsid /system/bin/sh /data/local/station/handoff.sh </dev/null >/dev/null 2>&1 & )'
if ! $B grep -q 'station/handoff.sh' $RC; then
	mount -o remount,rw /system
	[ -e $RC.before-handoff ] || cp $RC $RC.before-handoff
	# right after the keeper's line, before quasar's onboot.sh and rc.local's
	# own "wait" / "exit 0" (a line after them never runs)
	$B awk -v line="$line" '
		/station-handoff|station\/handoff/ { next }
		{ print }
		!done && /station\/keeper\.sh/ { print line; done = 1 }
		END { if (!done) exit 1 }
	' $RC > $RC.new
	cat $RC.new > $RC
	rm $RC.new
	sync
	mount -o remount,ro /system || true
fi
echo "installed: $($B grep -n 'station/' $RC | $B tr '\n' ' ')"
