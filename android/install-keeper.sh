#!/system/bin/sh
# Install keeper.sh on Yandex Android (run as full root: telnet 2323 or SSH):
#   sh install-keeper.sh /path/to/keeper.sh
# - the keeper in /data/local/station, started from rc.local and now;
# - quasar cannot switch ADB off: "activate_adb.sh deactivate" does nothing,
#   the activation markers cannot be removed (chattr +i, where there is one);
# - rc.local sets network ADB at every boot.
# Originals are kept as *.orig. Idempotent.
set -e
src=${1:?usage: install-keeper.sh keeper.sh}
S=/data/local/station
Q=/system/vendor/quasar
RC=/system/etc/rc.local

mkdir -p $S
cp "$src" $S/keeper.sh
chmod 755 $S/keeper.sh

# the networks that work now are the first working copy
mkdir -p $S/wifi-good
cp -p /data/misc/wifi/wpa_supplicant.conf /data/misc/wifi/networkHistory.txt $S/wifi-good/

# ADB markers, kept
touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb
if toybox chattr +i /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb 2>/dev/null; then
	echo "markers: immutable"
else
	echo "markers: no chattr here (deactivate is a no-op anyway)"
fi

mount -o rw,remount /system
# activate_adb.sh: "deactivate" does nothing
[ -f $Q/activate_adb.sh.orig ] || cp -p $Q/activate_adb.sh $Q/activate_adb.sh.orig
if ! grep -q "station keeper" $Q/activate_adb.sh; then
	{
		head -n 1 $Q/activate_adb.sh.orig
		echo 'case " $* " in *" deactivate "*) echo "$(date): deactivate ignored (station keeper)" >> /data/quasar/quasar_adb.log; exit 0 ;; esac'
		tail -n +2 $Q/activate_adb.sh.orig
	} > $S/activate_adb.sh.new
	cat $S/activate_adb.sh.new > $Q/activate_adb.sh
	rm $S/activate_adb.sh.new
fi
# rc.local: network ADB and the keeper, before quasar's onboot.sh
[ -f $RC.orig ] || cp -p $RC $RC.orig
if ! grep -q "station keeper" $RC; then
	while IFS= read -r line; do
		if [ "$line" = "/system/vendor/quasar/onboot.sh" ]; then
			echo '# --- station keeper (station-linux android/keeper.sh): network ADB, SSH, Wi-Fi copy ---'
			echo 'setprop service.adb.tcp.port 5555'
			echo 'start adbd'
			echo "( setsid /system/bin/sh $S/keeper.sh </dev/null >/dev/null 2>&1 & )"
			echo
		fi
		printf '%s\n' "$line"
	done < $RC > $S/rc.local.new
	cat $S/rc.local.new > $RC
	rm $S/rc.local.new
fi
sync
mount -o ro,remount /system

# and now
( setsid /system/bin/sh $S/keeper.sh </dev/null >/dev/null 2>&1 & )
sleep 1
echo "keeper: $(cat $S/keeper.pid 2>/dev/null) running: $(kill -0 "$(cat $S/keeper.pid)" 2>/dev/null && echo yes || echo no)"
echo "rc.local:"; grep -n -B1 -A4 "station keeper" $RC
echo "activate_adb.sh line 2: $(sed -n 2p $Q/activate_adb.sh | cut -c1-60)"
