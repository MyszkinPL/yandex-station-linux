#!/system/bin/sh
# Keeps our way into Yandex Android open, whatever quasar or the network does.
# Started from /system/etc/rc.local (android/install-keeper.sh), one instance.
#
# Every 30 s:
# - ADB on the network (5555) and SSH (dropbear) run; what died is started again;
# - Wi-Fi: once the Station has had an address for 5 minutes, Android's saved
#   networks are kept as the copy that works (a network changed on purpose
#   becomes the new copy); if it then has no address for 10 minutes and the
#   saved networks differ from that copy, the copy is put back and Wi-Fi
#   restarted — Android rolled its own saved networks back once and the
#   Station was off the network in every system.

S=/data/local/station
LOG=$S/keeper.log
GOOD=$S/wifi-good
WIFI=/data/misc/wifi
PIDF=$S/keeper.pid
TICK=30
SAVE_AFTER=300       # seconds with an address before the copy is taken
RESTORE_AFTER=600    # seconds without an address before the copy goes back

mkdir -p $S $GOOD
if [ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then
	exit 0
fi
echo $$ > $PIDF

say() {
	echo "$(date '+%F %T') $*" >> $LOG
	# a short log: the last ~200 lines
	if [ "$(wc -l < $LOG)" -gt 400 ]; then
		tail -n 200 $LOG > $LOG.new && mv $LOG.new $LOG
	fi
}

have_ip() { ip -4 addr show wlan0 2>/dev/null | grep -q "inet "; }

same_as_good() {
	for f in wpa_supplicant.conf networkHistory.txt; do
		[ -f $GOOD/$f ] || return 1
		cmp -s $WIFI/$f $GOOD/$f || return 1
	done
	return 0
}

save_good() {
	cp -p $WIFI/wpa_supplicant.conf $GOOD/wpa_supplicant.conf.new &&
		cp -p $WIFI/networkHistory.txt $GOOD/networkHistory.txt.new &&
		mv $GOOD/wpa_supplicant.conf.new $GOOD/wpa_supplicant.conf &&
		mv $GOOD/networkHistory.txt.new $GOOD/networkHistory.txt &&
		say "wifi: saved networks kept as the working copy"
}

restore_good() {
	say "wifi: no address for ${RESTORE_AFTER}s and saved networks changed: putting the working copy back"
	cp $GOOD/wpa_supplicant.conf $WIFI/wpa_supplicant.conf
	cp $GOOD/networkHistory.txt $WIFI/networkHistory.txt
	chown wifi:wifi $WIFI/wpa_supplicant.conf; chmod 660 $WIFI/wpa_supplicant.conf
	chown system:system $WIFI/networkHistory.txt; chmod 600 $WIFI/networkHistory.txt
	sync
	svc wifi disable
	sleep 3
	svc wifi enable
}

say "keeper started (pid $$)"
up=0; down=0
while true; do
	# ADB on the network
	if [ "$(getprop service.adb.tcp.port)" != 5555 ]; then
		setprop service.adb.tcp.port 5555
		stop adbd; start adbd
		say "adb: port was '$(getprop service.adb.tcp.port)', set 5555 and restarted"
	elif [ "$(getprop init.svc.adbd)" != running ]; then
		start adbd
		say "adb: was not running, started"
	fi
	# SSH
	if ! ps | grep -q "[d]ropbear"; then
		/data/dropbear/dropbear -p 22 -r /data/dropbear/dropbear_ed25519_host_key && say "ssh: dropbear was gone, started"
	fi
	# Wi-Fi
	if have_ip; then
		up=$((up + TICK)); down=0
		if [ $up -ge $SAVE_AFTER ] && ! same_as_good; then
			save_good
		fi
	else
		down=$((down + TICK)); up=0
		if [ $down -ge $RESTORE_AFTER ] && [ -f $GOOD/wpa_supplicant.conf ] && ! same_as_good; then
			restore_good
			down=0
		fi
	fi
	sleep $TICK
done
