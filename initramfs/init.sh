#!/bin/busybox sh
# Stage B: bring up Wi-Fi and SSH on the mainline kernel, keep a log in the
# unused tail of misc. Android's /data is mounted read-only; Debian tools
# run from it through a RAM overlay.
export PATH=/bin
exec </dev/null >/dev/null 2>&1
/bin/busybox --install -s /bin
mkdir -p /proc /sys /dev /tmp /run
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /sys/kernel/debug
mount -t devpts devpts /dev/pts
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
exec >/dev/kmsg 2>&1

L=/tmp/b.log
say() { echo "station-b: $*" > /dev/kmsg; echo "$*" >> $L; echo ">> $*" > /dev/tty0 2>/dev/null; }

# Partitions are found by where they are on the eMMC (vendor MBR/EBR chain),
# not by number: a kernel may number the logical ones differently.
MISC_START=4464640          # sectors
MISC_SECTORS=32768          # 16 MiB
DATA_START=12559356         # Android /data (ext4), mounted read-only
DATA_SECTORS=2710532
CACHE_START=4562944         # Android /cache (ext4): our persistent layer lives
CACHE_SECTORS=3145728       # in its station/ directory, the rest is Android's
LOG_SEEK=3072               # 4 KiB blocks -> 12 MiB into misc
LOG_BLOCKS=1024             # 4 MiB, up to the end of misc
MAGIC=STATION-MAINLINE
# sha256 of 4 MiB of zeros; a literal, so a failing pipeline can never "match"
ZERO4M_SHA=bb9f8df61474d25e71fa00722318cd387396ca1736605e1248821cc0de3d3af8

# name of the mmcblk partition with this start and size, if exactly one
part_at() {
	n=""; c=0
	for d in /sys/class/block/mmcblk*p*; do
		[ "$(cat $d/start 2>/dev/null)" = "$1" ] && [ "$(cat $d/size 2>/dev/null)" = "$2" ] &&
			{ n=${d##*/}; c=$((c+1)); }
	done
	[ $c = 1 ] && echo $n
}

HOLD_OK=0                  # 0: stay (station.hold=N on the command line:
HOLD_FAIL=0                # N seconds, then back to Android; for trying kernels)
for a in $(cat /proc/cmdline); do
	case "$a" in station.hold=*) HOLD_OK=${a#station.hold=}; HOLD_FAIL=$HOLD_OK ;; esac
done

say "init started, $(uname -r)"
# our services log into the kernel log (os/klog): no rate limit for them
echo on > /proc/sys/kernel/printk_devkmsg

# --- misc log target checks (unchanged from stage A) ---
i=0
while [ -z "$(part_at $MISC_START $MISC_SECTORS)" ] && [ $i -lt 40 ]; do sleep 0.25; i=$((i+1)); done
P=$(part_at $MISC_START $MISC_SECTORS)
DATA=$(part_at $DATA_START $DATA_SECTORS)
CACHE=$(part_at $CACHE_START $CACHE_SECTORS)
say "misc: ${P:-not found}, data: ${DATA:-not found}, cache: ${CACHE:-not found}"
for d in /sys/class/block/mmcblk*p*; do echo "  ${d##*/} $(cat $d/start) $(cat $d/size)"; done >> $L
why=""
[ -n "$P" ] && [ -b /dev/$P ] || why="no misc partition"
[ -z "$why" ] && [ "$(cat /sys/class/block/$P/start)" = "$MISC_START" ] || why="${why:-start mismatch $(cat /sys/class/block/$P/start 2>/dev/null)}"
[ -z "$why" ] && [ "$(cat /sys/class/block/$P/size)" = "$MISC_SECTORS" ] || why="${why:-size mismatch $(cat /sys/class/block/$P/size 2>/dev/null)}"
if [ -z "$why" ]; then
	region_sha=$(dd if=/dev/$P bs=4096 skip=$LOG_SEEK count=$LOG_BLOCKS 2>/dev/null | sha256sum | cut -d' ' -f1)
	head16=$(dd if=/dev/$P bs=4096 skip=$LOG_SEEK count=1 2>/dev/null | head -c 16)
	if [ "$region_sha" != "$ZERO4M_SHA" ] && [ "$head16" != "$MAGIC" ]; then
		why="target region not empty (sha $region_sha)"
	fi
fi

# Hints from the previous boot's log, read before this boot overwrites it:
# the AP's channel (from "iw dev wlan0 link" after "Connected to") lets
# wpa_supplicant scan one channel instead of all, and the old address goes to
# udhcpc as the requested IP. Both are only hints.
HINT_FREQ=""; HINT_IP=""
if [ -z "$why" ] && [ "$head16" = "$MAGIC" ]; then
	dd if=/dev/$P bs=4096 skip=$LOG_SEEK count=16 2>/dev/null | tr -d '\000' > /tmp/prev.log
	HINT_FREQ=$(awk '/^Connected to/ { c = 1 } c && $1 == "freq:" { print int($2); exit }' /tmp/prev.log)
	HINT_IP=$(grep -m1 -oE 'IP [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ' /tmp/prev.log | cut -d' ' -f2)
	case "$HINT_FREQ" in 2[0-9][0-9][0-9]|5[0-9][0-9][0-9]|6[0-9][0-9][0-9]) ;; *) HINT_FREQ="" ;; esac
fi

writelog() {
	{
		echo "$MAGIC-ALIVE-B1 ($1)"
		echo "uname: $(uname -a)"
		echo "cmdline: $(cat /proc/cmdline)"
		echo "--- stage B"; cat $L
		echo "--- devices_deferred"; cat /sys/kernel/debug/devices_deferred
		echo "--- net"; ip addr; ip route
		[ -f /run/wpa.log ] && { echo "--- wpa_supplicant"; tail -c 32768 /run/wpa.log; }
		echo "--- dmesg"; dmesg
		echo "--- END"
	} > /tmp/log 2>&1
	if [ -z "$why" ]; then
		head -c 4190208 /tmp/log > /tmp/log.cut
		dd if=/tmp/log.cut of=/dev/$P bs=4096 seek=$LOG_SEEK conv=notrunc 2>/dev/null
		sync
		blockdev --flushbufs /dev/$P
	fi
}

# Keep the SoC alive while we work. SIGKILL (not TERM: that would do the
# magic close and stop the watchdog) lets it reset the SoC within 16 s.
watchdog -t 4 -T 16 /dev/watchdog
say "watchdog feeder: $(pidof watchdog)"

# --- read-only look at the RTC oscillator (decides whether the RTC driver is safe) ---
for a in 0x01F00000 0x01F00004 0x01F00060 0x01000010; do
	echo "devmem $a = $(devmem $a 32 2>&1)" >> $L
done

# --- what the shim did on the PMIC (AXP803 DLDO4 = Wi-Fi VDDIO) ---
S=0x4E400000
if [ "$(devmem $S 32)" = "0x324D4853" ]; then
	for o in 08:ATF 10:ID 14:PWR2 18:DLDO4V 1C:DCDC2 20:DCDC5 24:WRITE 28:PWR2_NEW 2C:DCDC2_NEW 30:DCDC5_NEW 34:RESULT; do
		echo "shim ${o#*:} = $(devmem $((S + 0x${o%%:*})) 32)" >> $L
	done
	case $(devmem $((S + 0x34)) 32) in
	0x00000001) r="DLDO4 enabled" ;;
	0x00000002) r="DLDO4 was already on" ;;
	0x00000003) r="PMIC checks failed, nothing written" ;;
	*) r="PMIC access through ATF failed, nothing written" ;;
	esac
	say "shim pmic: $r"
else
	say "shim pmic: no log"
fi

[ -n "$why" ] && say "misc log disabled: $why"
writelog early

result=fail
# --- loopback: services talk over localhost (SSH forwards, local ports) ---
ip link set lo up

# --- Wi-Fi ---
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
if [ -e /sys/class/net/wlan0 ]; then
	say "wlan0 present"
	# the kernel takes the module's own address from its OTP; an
	# explicit one can still be given in /etc/station/wifi-mac
	[ -s /etc/station/wifi-mac ] && ip link set wlan0 address "$(cat /etc/station/wifi-mac)"
	ip link set wlan0 up && say "wlan0 up"
else
	say "NO wlan0"
	dmesg | grep -iE "brcm|mmc1|sdio|pwrseq" >> $L
fi

# --- the root filesystem ---
# Ours: /cache/station/rootfs, built by CI from Debian packages
# (scripts/build-rootfs.sh), read-only, with a layer in RAM on top: it is the
# same at every boot. What must be kept lives in /cache/station/persist and is
# bound in: /opt/station (services, settings, Wi-Fi networks), the Bluetooth
# pairings, chrony's drift, the SSH host key. /cache/station itself is
# /station inside.
# A new root filesystem (update rootfs-install leaves rootfs.try) is tried
# once: that boot turns the mark into rootfs.trying, and the health loop
# below removes it once our services have run steadily on it. A boot that
# never got there leaves rootfs.trying, and the next one puts that root
# filesystem aside (rootfs.failed) and comes up on the one before it
# (rootfs.old), with the same kept state.
# The last way out, with no root filesystem of ours at all: Debian from
# Android's /data, read-only, under a layer kept in /cache/station/root (in
# RAM if /cache cannot be used). station/root.reset: start that layer clean.
R=/newroot
ROOT=""
if [ -e /sys/class/net/wlan0 ]; then
	blockdev --setro /dev/$DATA
	mkdir -p /mnt/data /mnt/cache /run/ovl $R
	# Android's saved Wi-Fi networks are read from /data either way
	mount -t ext4 -o ro,noload /dev/$DATA /mnt/data || say "cannot mount /data"
	C=/mnt/cache/station
	if [ -n "$CACHE" ] && mount -t ext4 -o rw,noatime /dev/$CACHE /mnt/cache; then
		mkdir -p $C
		# one replaced while it was still on trial (update rootfs-install)
		rm -rf $C/rootfs.untried
		if [ -e $C/rootfs.trying ]; then
			rm -rf $C/rootfs.failed
			[ -d $C/rootfs ] && mv $C/rootfs $C/rootfs.failed
			[ -d $C/rootfs.old ] && mv $C/rootfs.old $C/rootfs
			rm -f $C/rootfs.trying && sync
			say "the new root filesystem did not come up: put aside as rootfs.failed, back on the one before"
		elif [ -e $C/rootfs.try ]; then
			mv $C/rootfs.try $C/rootfs.trying && sync
			say "trying the new root filesystem"
		fi
		if [ -x $C/rootfs/usr/sbin/wpa_supplicant ] && [ -x $C/rootfs/usr/sbin/dropbear ]; then
			mount -t tmpfs tmpfs /run/ovl
			mkdir -p /run/ovl/u /run/ovl/w
			if mount -t overlay overlay -o lowerdir=$C/rootfs,upperdir=/run/ovl/u,workdir=/run/ovl/w $R; then
				ROOT=own
				P=$C/persist
				mkdir -p $P/opt-station $P/bluetooth $P/chrony $P/dropbear
				# the first boot on it brings over what the old layer kept
				if [ ! -e $P/.migrated ] && [ -d $C/root/opt/station ]; then
					cp -a $C/root/opt/station/. $P/opt-station/
					cp -a $C/root/var/lib/bluetooth/. $P/bluetooth/ 2>/dev/null
					cp -a $C/root/etc/dropbear/. $P/dropbear/ 2>/dev/null
					touch $P/.migrated && say "kept state brought over from the old layer"
				fi
				mkdir -p $R/opt/station $R/var/lib/bluetooth $R/var/lib/chrony $R/etc/dropbear $R/station
				mount --bind $P/opt-station $R/opt/station
				mount --bind $P/bluetooth $R/var/lib/bluetooth
				mount --bind $P/chrony $R/var/lib/chrony
				# the SSH host key: the same at every boot, or clients cry wolf
				mount --bind $P/dropbear $R/etc/dropbear
				mount --bind $C $R/station
				say "root filesystem: ours ($(cat $C/rootfs/etc/station-rootfs 2>/dev/null || echo unknown)), $(df -h /mnt/cache | awk 'NR == 2 { print $4 }') free"
			else
				umount /run/ovl
			fi
		fi
	fi
	if [ -z "$ROOT" ] && [ -x /mnt/data/local/debian/usr/sbin/wpa_supplicant ]; then
		upper=""
		if mountpoint -q /mnt/cache; then
			if [ -e $C/root.reset ]; then
				rm -rf $C/root $C/work $C/root.reset && say "persistent layer reset"
			fi
			mkdir -p $C/root $C/work && upper=$C/root work=$C/work
		fi
		if [ -n "$upper" ] && mount -t overlay overlay -o lowerdir=/mnt/data/local/debian,upperdir=$upper,workdir=$work $R; then
			ROOT=debian
			say "debian overlay ready, layer on flash ($(df -h /mnt/cache | awk 'NR == 2 { print $4 }') free)"
		else
			mountpoint -q /run/ovl || mount -t tmpfs tmpfs /run/ovl
			mkdir -p /run/ovl/u2 /run/ovl/w2
			mount -t overlay overlay -o lowerdir=/mnt/data/local/debian,upperdir=/run/ovl/u2,workdir=/run/ovl/w2 $R && ROOT=debian
			say "debian overlay ready, layer in RAM (${CACHE:-no cache}: not usable)"
		fi
		mountpoint -q /mnt/cache && mkdir -p $R/station && mount --bind $C $R/station
	fi
	if [ -n "$ROOT" ]; then
		for m in proc sys dev dev/pts; do mount --bind /$m $R/$m; done
		mount -t tmpfs tmpfs $R/run
		mount -t tmpfs tmpfs $R/tmp
	else
		say "no root filesystem: neither ours nor Debian in /data"
	fi
fi

# --- our services (/opt/station/start): before the network, so the ring
# shows the boot and the buttons work at once; each is kept running ---
if [ -x $R/opt/station/start ]; then
	chroot $R /usr/bin/env -i PATH=/opt/station/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
		/opt/station/start >> $L 2>&1 &
	say "services started"
fi

if [ -x $R/usr/sbin/wpa_supplicant ]; then
	CH="chroot $R /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root"
	say "hints: freq=${HINT_FREQ:-none} ip=${HINT_IP:-none}"

	# Sound: the drivers are built in and probe on their own (the amplifiers
	# asynchronously, ~0.5 s each); once both cards are there, set the mic
	# ADCs up and give the speakers a quiet volume — the safe level if
	# nothing else ever sets one. Then /run/station/sound-ready hands the
	# speakers over (whatever came of it): audiod waits for it and from then
	# on alone owns the volume. Not tied to the network: alarms sound without
	# it. In the background, so it holds nothing up.
	(
		i=0
		while ! { [ -e /proc/asound/snddaudio0 ] && [ -e /proc/asound/snddaudio1 ]; } && [ $i -lt 150 ]; do
			sleep 0.1; i=$((i+1))
		done
		if [ $i -ge 150 ]; then
			say "sound: cards missing after 15 s"
		elif cp /etc/station/station-audio-init.sh /etc/station/station-mics-init.sh $R/run/ &&
		     $CH sh /run/station-audio-init.sh >> $L 2>&1; then
			say "sound ready"
		else
			say "sound: setup failed"
		fi
		mkdir -p $R/run/station && echo done > $R/run/station/sound-ready
	) &

	# SSH from the start, whatever the network does: dropbear listens on
	# every address the Station gets, now or later
	mkdir -p $R/root/.ssh && chmod 700 $R/root/.ssh
	cp /etc/station/authorized_keys $R/root/.ssh/authorized_keys && chmod 600 $R/root/.ssh/authorized_keys
	mkdir -p $R/etc/dropbear
	$CH dropbear -R -E -p 22 >> $L 2>&1

	mkdir -p $R/usr/local/sbin
	cat > $R/usr/local/sbin/station-reboot <<'RB'
#!/bin/sh
# Leave mainline: stop feeding the watchdog; the SoC resets within 16 s.
echo "station: resetting through the watchdog" > /dev/kmsg
pkill -9 -x watchdog
RB
	chmod 755 $R/usr/local/sbin/station-reboot
	cp /bin/kexec $R/usr/local/sbin/kexec
	cat > $R/usr/local/sbin/station-kexec <<'KX'
#!/bin/sh
# Start another mainline kernel without U-Boot: station-kexec Image station.dtb
# The kernel command line comes from the new DTB's bootargs. The SoC watchdog
# keeps running across kexec (watchdog.stop_on_reboot=0), so a kernel that
# does not come up resets the Station back to Android within 16 s.
set -e
img=${1:?usage: station-kexec Image station.dtb}
dtb=${2:?usage: station-kexec Image station.dtb}
grep -q 'watchdog.stop_on_reboot=0' /proc/cmdline ||
	{ echo "refusing: this kernel would stop the watchdog on kexec"; exit 1; }
grep -aq 'watchdog.stop_on_reboot=0' "$dtb" ||
	{ echo "refusing: $dtb bootargs lack watchdog.stop_on_reboot=0"; exit 1; }
/usr/local/sbin/kexec -l "$img" --dtb="$dtb"
echo "station: kexec into $img" > /dev/kmsg
sync
/usr/local/sbin/kexec -e
KX
	chmod 755 $R/usr/local/sbin/station-kexec
	# wpa_cli's action on a (re)connection, to another access point or
	# network too: the lease is asked for again at once
	cat > $R/usr/local/sbin/station-net-event <<'NE'
#!/bin/sh
# wpa_cli -a: $1 interface, $2 CONNECTED | DISCONNECTED
[ "$2" = CONNECTED ] && kill -USR1 "$(cat /run/udhcpc.pid 2>/dev/null)" 2>/dev/null
exit 0
NE
	chmod 755 $R/usr/local/sbin/station-net-event

	# Every network we know: first our own (added in the panel, kept in the
	# persistent layer: /opt/station/etc/wifi.conf), then every one Android
	# has saved, with only the fields a plain supplicant needs (Android adds
	# fields upstream rejects). Whole lines are kept: a passphrase may contain
	# spaces; a block ends only on a lone "}". EAP networks (no way to bring
	# certificates over) and disabled ones are left out.
	# "@FREQ@" is a placeholder for the channel hint.
	awk '
		/^[ \t]*network=\{[ \t]*$/ { inb = 1; blk = ""; ssid = 0; skip = 0; next }
		inb && /^[ \t]*\}[ \t]*$/ {
			if (ssid && !skip) printf "network={\n\tscan_ssid=1\n@FREQ@\n%s}\n", blk
			inb = 0; next
		}
		inb && /^[ \t]*key_mgmt=.*(EAP|IEEE8021X)/ { skip = 1 }
		inb && /^[ \t]*disabled=1/ { skip = 1 }
		inb && /^[ \t]*(ssid|psk|key_mgmt|priority|auth_alg|wep_key[0-3]|wep_tx_keyidx)=/ {
			l = $0; sub(/^[ \t]+/, "", l); blk = blk "\t" l "\n"
			if (l ~ /^ssid=/) ssid = 1
		}
	' $(ls $R/opt/station/etc/wifi.conf 2>/dev/null) /mnt/data/misc/wifi/wpa_supplicant.conf > /tmp/net
	if [ -s /tmp/net ]; then
		# $1 = scan_freq (empty: scan everything)
		write_wpa() {
			{
				echo "ctrl_interface=/run/wpa_supplicant"
				if [ -n "$1" ]; then sed "s/^@FREQ@\$/	scan_freq=$1/" /tmp/net
				else sed "/^@FREQ@\$/d" /tmp/net; fi
			} > $R/etc/wpa-station.conf
			chmod 600 $R/etc/wpa-station.conf
		}
		# with its debug output while it connects (the boot's log shows why it
		# did not), down to INFO once connected: the log lives in RAM
		start_wpa() {
			$CH wpa_supplicant -B -i wlan0 -D nl80211 -c /etc/wpa-station.conf -f /run/wpa.log -d
			$CH wpa_cli -i wlan0 -a /usr/local/sbin/station-net-event -B
		}
		# up to $1 tenths of a second for the 4-way handshake to complete
		wait_wpa() {
			i=0
			while [ $i -lt $1 ]; do
				$CH wpa_cli -i wlan0 status 2>/dev/null | grep -q "^wpa_state=COMPLETED" && return 0
				sleep 0.1; i=$((i+1))
			done
			return 1
		}
		write_wpa "$HINT_FREQ"
		start_wpa
		if [ -n "$HINT_FREQ" ] && ! wait_wpa 40; then
			say "not connected on hinted $HINT_FREQ MHz, scanning all channels"
			write_wpa ""
			$CH wpa_cli -i wlan0 reconfigure >/dev/null
		fi
		wait_wpa 450
		ln -sf $R/run/wpa.log /run/wpa.log
		$CH iw dev wlan0 link >> $L 2>&1
		if $CH iw dev wlan0 link 2>/dev/null | grep -q "^Connected"; then
			say "associated with $($CH wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p')"
		else
			say "NOT associated yet with any of $(grep -c '^network=' /tmp/net) saved networks (still trying)"
		fi
		# the channel hint only served this boot: kept, it would stop the
		# Station from finding its network on another channel, ever
		if [ -n "$HINT_FREQ" ]; then
			write_wpa ""
			for n in $($CH wpa_cli -i wlan0 list_networks 2>/dev/null | awk 'NR > 1 { print $1 }'); do
				$CH wpa_cli -i wlan0 set_network $n scan_freq "" >/dev/null
			done
		fi
		$CH wpa_cli -i wlan0 log_level INFO >/dev/null
		# DHCP for as long as we run: the lease is renewed, a lost one is
		# asked for again, and a (re)connection asks at once (station-net-event)
		export NEWROOT=$R
		udhcpc -i wlan0 -s /udhcpc.sh -t 8 -T 3 -b -p $R/run/udhcpc.pid ${HINT_IP:+-r $HINT_IP}
		if ip -4 addr show wlan0 2>/dev/null | grep -q "inet " && pidof dropbear >/dev/null; then
			result=ok
		fi
		say "IP $(cat /tmp/ip 2>/dev/null || echo none)  ssh: $(pidof dropbear >/dev/null && echo up || echo DOWN)"
	else
		say "no usable network in our wifi.conf or Android's wpa_supplicant.conf"
	fi
fi

writelog "$result"
[ "$result" = ok ] && hold=$HOLD_OK || hold=$HOLD_FAIL
if [ "$hold" = 0 ]; then
	say "result: $result, staying up"
else
	say "result: $result, staying up ${hold}s (station.hold), then watchdog reset to Android"
fi

# While up, init keeps the base: the network and SSH. Without the network
# the Station goes on — alarms, timers, Bluetooth and the ring do not need
# it — shows it on the ring, and gets it back; losing it is never a reason
# to leave (a reset goes to Android). Whatever of the base died is started
# again. The SoC watchdog stays fed: it is for a hung kernel.
# The ring's "offline" is init's to say: told again when ringd has lost it
# (a restart), as every owner does.
NET_GRACE=30
net_up() {
	[ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = up ] &&
		ip -4 addr show wlan0 2>/dev/null | grep -q "inet "
}
keep_base() {
	pidof dropbear >/dev/null || { say "dropbear was gone: starting it again"; $CH dropbear -R -E -p 22 >> $L 2>&1; }
	[ -s /tmp/net ] || return
	if ! pidof wpa_supplicant >/dev/null; then
		say "wpa_supplicant was gone: starting it again"
		$CH pkill -x wpa_cli
		start_wpa
		$CH wpa_cli -i wlan0 log_level INFO >/dev/null
	fi
	pidof wpa_cli >/dev/null || $CH wpa_cli -i wlan0 -a /usr/local/sbin/station-net-event -B
	if ! kill -0 "$(cat $R/run/udhcpc.pid 2>/dev/null)" 2>/dev/null; then
		say "udhcpc was gone: starting it again"
		udhcpc -i wlan0 -s /udhcpc.sh -t 8 -T 3 -b -p $R/run/udhcpc.pid
	fi
}
# the pids of our core services (a restart changes one)
CORE="ringd audiod timerd stationd webd"
core_pids() { for s in $CORE; do pidof $s || echo none; done | tr '\n' ' '; }
left=$hold; bad=0; seen=""
while [ "$hold" = 0 ] || [ $left -gt 0 ]; do
	sleep 10; left=$((left - 10))
	[ -n "$CH" ] || continue
	keep_base
	if net_up; then
		[ $bad -ge $NET_GRACE ] && say "network back"
		bad=0
	else
		bad=$((bad + 10))
		[ $bad = $NET_GRACE ] && say "no network for ${bad}s: the ring shows it, still trying"
		# now and then a push: look for the networks again
		[ $((bad % 120)) = 0 ] && $CH wpa_cli -i wlan0 reassociate >/dev/null
	fi
	want=false; [ $bad -ge $NET_GRACE ] && want=true
	if [ -S $R/run/ringd.sock ] && ! chroot $R /opt/station/bin/ringd ctl status 2>/dev/null | grep -q "\"offline\":$want"; then
		chroot $R /opt/station/bin/ringd ctl offline $([ $want = true ] && echo on || echo off) >/dev/null
	fi
	# a root filesystem on trial is ours once all its core services run and
	# none of them restarted between two looks
	if [ -e /mnt/cache/station/rootfs.trying ] && [ "$ROOT" = own ]; then
		now=$(core_pids)
		case "$now" in
		*none*) seen="" ;;
		*) if [ "$now" = "$seen" ]; then
			rm -f /mnt/cache/station/rootfs.trying && sync
			say "the new root filesystem works: kept"
		   else
			seen=$now
		   fi ;;
		esac
	fi
done
writelog "$result, final"
say "resetting through the watchdog"
kill -9 $(pidof watchdog) 2>/dev/null
sleep 30
reboot -f
