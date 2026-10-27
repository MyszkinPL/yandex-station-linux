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

# Back to Yandex Android, and stay there (the log says so; Android leaves the
# Station alone then): the way out when ours could never be reached at all.
to_android() {
	say "to Android, to stay: $1"
	writelog "to Android: $1"
	[ -z "$why" ] && printf '%s-STAY\n' $MAGIC | dd of=/dev/$P bs=4096 seek=$LOG_SEEK conv=notrunc,sync 2>/dev/null && sync
	kill -9 $(pidof watchdog) 2>/dev/null
	sleep 30
	reboot -f
}

result=fail
# --- loopback: services talk over localhost (SSH forwards, local ports) ---
ip link set lo up

# --- the vendor's firmware, from the Station's own Android ---
# Wi-Fi, Bluetooth and the amplifiers' register scripts are Yandex's files:
# not ours to publish, so not in this image. Every Station has them in its
# Android system partition (found, like the others, by where it is): copied
# from there at every boot, read-only, and checked against the known ones; a
# file that differs is used all the same and said so. The drivers that need
# them are modules, loaded after. Without them there is no Wi-Fi, and the
# rule below (no Wi-Fi device for two minutes: back to Android) applies.
SYSTEM_START=204800
SYSTEM_SECTORS=4194304
fw_from_android() {
	SYS=$(part_at $SYSTEM_START $SYSTEM_SECTORS)
	[ -n "$SYS" ] || { say "firmware: no Android system partition"; return; }
	blockdev --setro /dev/$SYS
	mkdir -p /mnt/system /lib/firmware/brcm
	mount -t ext4 -o ro,noload /dev/$SYS /mnt/system || { say "firmware: cannot mount Android's system"; return; }
	got=0; odd=""
	while read -r dst src sha; do
		if cp /mnt/system/$src /lib/firmware/$dst 2>/dev/null; then
			got=$((got+1))
			[ "$(sha256sum /lib/firmware/$dst | cut -d' ' -f1)" = "$sha" ] || odd="$odd ${dst##*/}"
		else
			say "firmware: no /system/$src in Android"
		fi
	done <<-FW
	brcm/brcmfmac4356-sdio.bin vendor/modules/fw_bcm4356a2_ag.bin ff7351dae9bd36f47a494579ae22330dcbeee61bf755e902c67b7bb418928e55
	brcm/brcmfmac4356-sdio.txt vendor/modules/nvram.txt fa23dcba44074022314e9ac2eafb5993cf47f0a5b75df27f770f3e542f991560
	brcm/BCM4356A2.hcd vendor/modules/BCM4354A2.hcd a39b2736e9f698c95d24ddc5dca222c4586c1cac76bda977cf20643dede86dc7
	tas5751m-2a.txt vendor/firmware/tas5751m-2a.txt 9df7ff949168a040f6f7db36a0c7ee4c1c932274622e9ac9d6f5d665864ddc1f
	tas5751m-2b.txt vendor/firmware/tas5751m-2b.txt 6fddd462a57681870ebba0ca22e902b6044e0c697bcea5d1540f33ea2efd450e
	FW
	umount /mnt/system
	say "firmware: $got of 5 from Android${odd:+, not the known one:$odd}"
}
fw_from_android
for m in brcmfmac snd-soc-tas571x hci_uart; do
	modprobe $m || say "cannot load $m"
done

# --- Wi-Fi ---
# Without the Wi-Fi device ours cannot be reached by anyone: no network, no
# access point to set one up. Up to two minutes for it, then Android.
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ $i -lt 240 ]; do sleep 0.5; i=$((i+1)); done
if [ -e /sys/class/net/wlan0 ]; then
	say "wlan0 present"
	# the kernel takes the module's own address from its OTP; an
	# explicit one can still be given in /etc/station/wifi-mac
	[ -s /etc/station/wifi-mac ] && ip link set wlan0 address "$(cat /etc/station/wifi-mac)"
	ip link set wlan0 up && say "wlan0 up"
else
	say "NO wlan0"
	dmesg | grep -iE "brcm|mmc1|sdio|pwrseq" >> $L
	to_android "no Wi-Fi device after 2 minutes"
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
				# (not $P: that is the misc partition the log goes to)
				KEEP=$C/persist
				mkdir -p $KEEP/opt-station $KEEP/bluetooth $KEEP/chrony $KEEP/dropbear
				# the first boot on it brings over what the old layer kept
				if [ ! -e $KEEP/.migrated ] && [ -d $C/root/opt/station ]; then
					cp -a $C/root/opt/station/. $KEEP/opt-station/
					cp -a $C/root/var/lib/bluetooth/. $KEEP/bluetooth/ 2>/dev/null
					cp -a $C/root/etc/dropbear/. $KEEP/dropbear/ 2>/dev/null
					touch $KEEP/.migrated && say "kept state brought over from the old layer"
				fi
				mkdir -p $R/opt/station $R/var/lib/bluetooth $R/var/lib/chrony $R/etc/dropbear $R/station
				mount --bind $KEEP/opt-station $R/opt/station
				mount --bind $KEEP/bluetooth $R/var/lib/bluetooth
				mount --bind $KEEP/chrony $R/var/lib/chrony
				# the SSH host key: the same at every boot, or clients cry wolf
				mount --bind $KEEP/dropbear $R/etc/dropbear
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
		# nothing to run SSH or the access point from: nobody could reach
		# the Station, and a power cut would bring it back here again
		to_android "no root filesystem: neither ours nor Debian in /data"
	fi
fi

# --- our services (/opt/station/start): before the network, so the ring
# shows the boot and the buttons work at once; each is kept running ---
if [ -x $R/opt/station/start ]; then
	chroot $R /usr/bin/env -i PATH=/opt/station/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
		/opt/station/start >> $L 2>&1 &
	say "services started"
fi

# The way back to Android that needs nothing but a hand: the Alice key held
# for HOLD_KEY seconds, the Station running. (Not at power-on: held while the
# power comes on it is the factory reset of the vendor U-Boot.) Read here in
# init, not by our services, so it works whatever they or the network do.
# The ring shows "no" just before. One event per dd: struct input_event on
# 64-bit is 24 bytes (timeval 16, type, code, value); as hex, type is chars
# 33-36, code 37-40, value 41-48, little-endian (EV_KEY 0100, KEY_ASSISTANT
# 0x247 4702; value 01000000 down, 00000000 up, 02000000 repeat).
HOLD_KEY=10
key_watch() {
	dev=""
	for e in /sys/class/input/event*; do
		[ "$(cat $e/device/name 2>/dev/null)" = gpio-keys ] && dev=/dev/input/${e##*/}
	done
	[ -n "$dev" ] || { say "no key device: no Alice-key way back to Android"; return; }
	say "Alice key held ${HOLD_KEY}s: back to Android ($dev)"
	timer=""
	while :; do
		ev=$(dd if=$dev bs=24 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
		[ ${#ev} = 48 ] || { sleep 1; continue; }
		[ "$(echo $ev | cut -c33-40)" = 01004702 ] || continue
		case $(echo $ev | cut -c41-48) in
		01000000)
			[ -n "$timer" ] && kill $timer 2>/dev/null
			(
				sleep $HOLD_KEY
				[ -S $R/run/ringd.sock ] && chroot $R /opt/station/bin/ringd ctl preview error 30 >/dev/null
				to_android "the Alice key held ${HOLD_KEY}s"
			) &
			timer=$!
			;;
		00000000)
			[ -n "$timer" ] && kill $timer 2>/dev/null
			timer=""
			;;
		esac
	done
}
key_watch &

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
	# The owner's way in, kept in persist/ssh (the installer puts it there):
	# their public keys, and/or a root password as its hash only.
	# /etc/station/authorized_keys: a key built into a developer's own image.
	mkdir -p $R/root/.ssh && chmod 700 $R/root/.ssh
	SSHK=/mnt/cache/station/persist/ssh
	for k in $SSHK/authorized_keys /etc/station/authorized_keys; do
		[ -s $k ] && { cp $k $R/root/.ssh/authorized_keys && chmod 600 $R/root/.ssh/authorized_keys; break; }
	done
	if [ -s $SSHK/root.hash ]; then
		h=$(head -1 $SSHK/root.hash)
		sed -i "s|^root:[^:]*:|root:$h:|" $R/etc/shadow && say "root password from persist/ssh"
	fi
	[ -s $R/root/.ssh/authorized_keys ] || [ -s $SSHK/root.hash ] || say "no SSH key and no root password: nobody can log in over SSH"
	mkdir -p $R/etc/dropbear
	$CH dropbear -R -E -p 22 >> $L 2>&1

	mkdir -p $R/usr/local/sbin
	cat > $R/usr/local/sbin/station-reboot <<'RB'
#!/bin/sh
# Restart: stop feeding the watchdog; the SoC resets within 16 s. Yandex
# Android comes up first and hands the Station back to us (its
# station-handoff.sh, android/), as after a power cut.
echo "station: resetting through the watchdog" > /dev/kmsg
pkill -9 -x watchdog
RB
	chmod 755 $R/usr/local/sbin/station-reboot
	# Back to Android to stay there (flashing a new recovery image, say): the
	# log in misc says "stay", and Android's hand-off leaves the Station alone.
	# Only where the log region is checked to be ours.
	if [ -z "$why" ]; then
		cat > $R/usr/local/sbin/station-android <<SA
#!/bin/sh
# To Yandex Android, and stay there (until a one-shot boot into recovery).
printf '$MAGIC-STAY\\n' | dd of=/dev/$P bs=4096 seek=$LOG_SEEK conv=notrunc,sync 2>/dev/null && sync &&
	echo "station: to Android, staying there" > /dev/kmsg && pkill -9 -x watchdog
SA
		chmod 755 $R/usr/local/sbin/station-android
	fi
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
	build_net() {
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
	}
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
	# until the process is gone (a new supplicant refuses a control socket an
	# old one still holds), at most 3 s
	wait_gone() {
		i=0
		while pidof $1 >/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
	}
	build_net
	if [ -s /tmp/net ]; then
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
		say "no usable network in our wifi.conf or Android's wpa_supplicant.conf: the access point comes up"
		export NEWROOT=$R
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
#
# The way back that needs nobody but a phone: with no network for AP_AFTER,
# the Station raises its own open access point "Станция-XXXX" (192.168.4.1,
# 2.4 GHz); a phone that joins gets an address and a DNS that sends every
# name to the Station, so it opens the panel by itself ("sign in to the
# network") on the Wi-Fi page. A network saved there (webd: wifi.conf and
# /run/station/wifi-changed) is tried at once; every AP_RETRY the Station
# also leaves the access point for TRY_FOR to look for the networks it
# knows, so it comes back by itself when the router does (after a power cut
# the router often takes longer than the Station). SSH answers on the access
# point too. /run/station/net-mode says which mode it is in (client, ap, try).
NET_GRACE=30
AP_AFTER=180
AP_RETRY=300
TRY_FOR=60
AP_IP=192.168.4.1
AP_SSID="Станция-$(cut -d: -f5,6 /sys/class/net/wlan0/address 2>/dev/null | tr -d : | tr a-f A-F)"
net_up() {
	[ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = up ] &&
		ip -4 addr show wlan0 2>/dev/null | grep "inet " | grep -vq "inet $AP_IP/"
}
set_mode() {
	MODE=$1
	mkdir -p $R/run/station && echo $1 > $R/run/station/net-mode
}
# the client side: supplicant with the known networks, DHCP
start_client() {
	ip addr flush dev wlan0
	build_net
	[ -s /tmp/net ] || { say "no known network to look for"; return 1; }
	write_wpa ""
	rm -f $R/run/wpa_supplicant/wlan0
	start_wpa
	$CH wpa_cli -i wlan0 log_level INFO >/dev/null
	udhcpc -i wlan0 -s /udhcpc.sh -t 8 -T 3 -b -p $R/run/udhcpc.pid
}
stop_client() {
	kill "$(cat $R/run/udhcpc.pid 2>/dev/null)" 2>/dev/null
	$CH pkill -x wpa_cli
	killall wpa_supplicant 2>/dev/null
	wait_gone wpa_supplicant
	ip addr flush dev wlan0
}
# what is around, for the panel's list (the access point cannot scan): a
# scan of its own, with a bare supplicant when none runs (no network known)
scan_list() {
	if ! pidof wpa_supplicant >/dev/null; then
		echo "ctrl_interface=/run/wpa_supplicant" > $R/etc/wpa-scan.conf
		rm -f $R/run/wpa_supplicant/wlan0
		$CH wpa_supplicant -B -i wlan0 -D nl80211 -c /etc/wpa-scan.conf
		sleep 1
	fi
	$CH wpa_cli -i wlan0 scan >/dev/null 2>&1
	i=0
	while [ $i -lt 8 ]; do
		sleep 1; i=$((i+1))
		[ $($CH wpa_cli -i wlan0 scan_results 2>/dev/null | wc -l) -gt 1 ] && [ $i -ge 4 ] && break
	done
	# an empty scan does not replace a list there was
	$CH wpa_cli -i wlan0 scan_results > $R/run/station/scan.txt.new 2>/dev/null
	if [ $(wc -l < $R/run/station/scan.txt.new) -gt 1 ] || [ ! -s $R/run/station/scan.txt ]; then
		mv $R/run/station/scan.txt.new $R/run/station/scan.txt
	else
		rm -f $R/run/station/scan.txt.new
	fi
}
start_ap() {
	mkdir -p $R/run/station
	scan_list
	stop_client
	ip addr add $AP_IP/24 dev wlan0
	cat > $R/etc/wpa-ap.conf <<AP
ctrl_interface=/run/wpa_supplicant
ap_scan=2
network={
	ssid="$AP_SSID"
	mode=2
	frequency=2437
	key_mgmt=NONE
}
AP
	cat > $R/etc/dnsmasq-ap.conf <<DM
interface=wlan0
bind-interfaces
except-interface=lo
no-resolv
no-hosts
dhcp-range=192.168.4.10,192.168.4.60,255.255.255.0,1h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
address=/#/$AP_IP
dhcp-leasefile=/run/dnsmasq-ap.leases
pid-file=/run/dnsmasq-ap.pid
DM
	rm -f $R/run/wpa_supplicant/wlan0
	$CH wpa_supplicant -B -i wlan0 -D nl80211 -c /etc/wpa-ap.conf -f /run/wpa-ap.log
	$CH dnsmasq --conf-file=/etc/dnsmasq-ap.conf
	set_mode ap
	say "access point '$AP_SSID' up ($AP_IP): join it with a phone to set Wi-Fi up"
}
stop_ap() {
	kill "$(cat $R/run/dnsmasq-ap.pid 2>/dev/null)" 2>/dev/null
	killall wpa_supplicant 2>/dev/null
	wait_gone wpa_supplicant
	ip addr flush dev wlan0
}
keep_base() {
	pidof dropbear >/dev/null || { say "dropbear was gone: starting it again"; $CH dropbear -R -E -p 22 >> $L 2>&1; }
	case $MODE in
	ap)
		pidof wpa_supplicant >/dev/null || { say "access point was gone: up again"; start_ap; }
		kill -0 "$(cat $R/run/dnsmasq-ap.pid 2>/dev/null)" 2>/dev/null || $CH dnsmasq --conf-file=/etc/dnsmasq-ap.conf
		;;
	*)
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
		;;
	esac
}
# the pids of our core services (a restart changes one)
CORE="ringd audiod timerd stationd webd"
core_pids() { for s in $CORE; do pidof $s || echo none; done | tr '\n' ' '; }
left=$hold; bad=0; seen=""; since=0; saved=""
[ -n "$CH" ] && set_mode client
while [ "$hold" = 0 ] || [ $left -gt 0 ]; do
	sleep 10; left=$((left - 10)); since=$((since + 10))
	[ -n "$CH" ] || continue
	# a network saved in the panel: tried now
	changed=""
	[ -e $R/run/station/wifi-changed ] && { rm -f $R/run/station/wifi-changed; changed=yes; build_net; }
	case $MODE in
	ap)
		# the timer's look waits while a phone is on the access point (someone
		# may be typing a password), up to three rounds
		phone=""
		$CH iw dev wlan0 station dump 2>/dev/null | grep -q "^Station" && [ $since -lt $((AP_RETRY * 3)) ] && phone=yes
		if [ -n "$changed" ] || { [ $since -ge $AP_RETRY ] && [ -z "$phone" ]; }; then
			if [ -n "$changed" ]; then why_try="a network was saved"; else why_try="every ${AP_RETRY}s"; fi
			say "leaving the access point to look for the known networks ($why_try)"
			stop_ap
			saved=$changed
			start_client && { set_mode try; since=0; } || { start_ap; since=0; }
		fi
		;;
	try)
		if net_up; then
			say "network back: $($CH wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p')"
			rm -f $R/run/station/net-failed
			set_mode client; bad=0
		elif [ $since -ge $TRY_FOR ]; then
			say "none of the known networks within ${TRY_FOR}s: the access point again"
			# a network just saved did not work: the page says so when the
			# phone is back on the access point (a wrong password?)
			[ -n "$saved" ] && date +%s > $R/run/station/net-failed
			start_ap; since=0
		fi
		;;
	client)
		if [ -n "$changed" ] && ! net_up; then
			write_wpa ""
			$CH wpa_cli -i wlan0 reconfigure >/dev/null
		fi
		;;
	esac
	keep_base
	if net_up; then
		# (back from the access point: the try branch says it, with the name)
		[ $bad -ge $NET_GRACE ] && [ $MODE != try ] && say "network back"
		[ $MODE != try ] && bad=0
	else
		bad=$((bad + 10))
		[ $bad = $NET_GRACE ] && say "no network for ${bad}s: the ring shows it, still trying"
		if [ $MODE = client ]; then
			# now and then a push: look for the networks again
			[ $((bad % 120)) = 0 ] && $CH wpa_cli -i wlan0 reassociate >/dev/null
			# no network for AP_AFTER, or none known at all: the access point
			if [ $bad -ge $AP_AFTER ] || [ ! -s /tmp/net ]; then
				start_ap; since=0
			fi
		fi
	fi
	# the ring: "no network", and "join my access point" over it while it is up
	if [ -S $R/run/ringd.sock ]; then
		ring=$(chroot $R /opt/station/bin/ringd ctl status 2>/dev/null)
		want=false; [ $bad -ge $NET_GRACE ] && want=true
		echo "$ring" | grep -q "\"offline\":$want" ||
			chroot $R /opt/station/bin/ringd ctl offline $([ $want = true ] && echo on || echo off) >/dev/null
		want=false; [ $MODE = ap ] && want=true
		echo "$ring" | grep -q "\"setup\":$want" ||
			chroot $R /opt/station/bin/ringd ctl setup $([ $want = true ] && echo on || echo off) >/dev/null
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
