#!/bin/sh
# From the mainline stage B (Debian overlay): start the Station's own
# Android (Quasar) on the mainline kernel through kexec, with the command
# line the vendor U-Boot builds for it.
#   usage: station-android-kexec Image quasar.dtb android-ramdisk.cpio.gz
# The serial number is derived from the SID eFuses exactly as U-Boot does
# (board/sunxi/common/sunxi_serial.c: %04x%08x%08x of SID[1] >> 16, SID[2],
# SID[3]; checked against the vendor command line), so nothing device
# specific is baked into any image.
set -e
img=${1:?usage: station-android-kexec Image quasar.dtb ramdisk.cpio.gz}
dtb=${2:?usage: station-android-kexec Image quasar.dtb ramdisk.cpio.gz}
rd=${3:?usage: station-android-kexec Image quasar.dtb ramdisk.cpio.gz}

sid=$(ls -d /sys/bus/nvmem/devices/sunxi-sid*/nvmem 2>/dev/null | head -1)
if [ -r "$sid" ]; then
	word() { echo 0x$(od -An -tx4 -j "$1" -N 4 "$sid" | tr -d ' \n'); }
else
	# kernels without NVMEM_SYSFS: the SID registers (0x01c14200 = SID[0])
	word() { busybox devmem $((0x01c14200 + $1)) 32; }
fi
sn=$(printf '%04x%08x%08x' $(( $(word 4) >> 16 )) $(word 8) $(word 12))
[ ${#sn} = 20 ] || { echo "bad serial number length ${#sn}"; exit 1; }

# the vendor layout (identical on every Station 1): U-Boot's partitions=
parts=bootloader@mmcblk0p2:env@mmcblk0p5:boot@mmcblk0p6:system@mmcblk0p7
parts=$parts:verity_block@mmcblk0p8:misc@mmcblk0p9:recovery@mmcblk0p10
parts=$parts:cache@mmcblk0p11:metadata@mmcblk0p12:private@mmcblk0p13
parts=$parts:frp@mmcblk0p14:rescue@mmcblk0p15:tinaos@mmcblk0p16:rback@mmcblk0p17
parts=$parts:secret@mmcblk0p18:alog@mmcblk0p19:lback@mmcblk0p20:rboot@mmcblk0p21
parts=$parts:media_data@mmcblk0p22:UDISK@mmcblk0p1

# Kernel side as in stage B (watchdog survives kexec, WDT restart, no
# PSCI SYSTEM_OFF); mem_sleep_default=s2idle: an Android suspend attempt
# must never reach the vendor ATF's SYSTEM_SUSPEND. rt_group_sched=1:
# Android init writes cpu.rt_runtime_us. snd-aloop card 4: Quasar's echo
# reference. Then U-Boot's androidboot.* arguments.
cmd="console=tty0 consoleblank=0 fbcon=font:TER16x32 video=HDMI-A-1:1920x1080@60"
cmd="$cmd loglevel=4 printk.devkmsg=on panic=5 clk_ignore_unused hw_protection=reboot"
cmd="$cmd watchdog.stop_on_reboot=0 mem_sleep_default=s2idle rt_group_sched=1"
cmd="$cmd snd_aloop.index=4 rdinit=/station-init partitions=$parts"
[ -n "$STATION_DEBUG" ] && cmd="$cmd station.debug=1"
cmd="$cmd androidboot.selinux=permissive androidboot.serialno=$sn androidboot.hardware=sun50iw1p1"

case "$cmd" in *watchdog.stop_on_reboot=0*) ;; *) echo "refusing: no watchdog.stop_on_reboot=0"; exit 1 ;; esac
grep -q 'watchdog.stop_on_reboot=0' /proc/cmdline ||
	{ echo "refusing: this kernel would stop the watchdog on kexec"; exit 1; }

/usr/local/sbin/kexec -l "$img" --dtb="$dtb" --initrd="$rd" --command-line="$cmd"
echo "station: kexec into Android on $(basename "$img")" > /dev/kmsg
sync
/usr/local/sbin/kexec -e
