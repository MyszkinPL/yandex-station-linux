#!/usr/bin/env python3
# Android (Quasar) mode ramdisk for the mainline kernel: the vendor boot.img
# ramdisk with the smallest changes that kernel needs.
#   usage: mkramdisk.py <vendor boot.img> <busybox-arm64> <station-android.sh> <out.cpio.gz>
# Changes, all in init.sun50iw1p1.rc plus two new files in /sbin:
#   - early-init: mount binderfs and link /dev/binder (ueventd of Android 6
#     knows only the misc device, which binderfs kernels do not have), start
#     station_wd;
#   - station_wd (/sbin/station-android.sh, own static busybox as
#     /sbin/station/busybox) instead of the vendor watchdogd.
import gzip, sys
sys.path.insert(0, sys.path[0] + "/../../..")
from bootimg import parse, cpio_entries, cpio_file

bootimg, busybox, script, out = sys.argv[1:5]
h = parse(open(bootimg, "rb").read())
ents = cpio_entries(gzip.decompress(h["ramdisk"]))
names = [n for n, _ in ents]
assert "init.sun50iw1p1.rc" in names and "TRAILER!!!" == names[-1]


def data_of(entry):
    raw = entry
    namesize, filesize = int(raw[94:102], 16), int(raw[54:62], 16)
    d0 = (110 + namesize + 3) & ~3
    return raw[d0:d0 + filesize]


rc = data_of(dict(ents)["init.sun50iw1p1.rc"]).decode()

old_early = "on early-init\n    mount debugfs debugfs /sys/kernel/debug/ mode=755\n"
assert rc.count(old_early) == 1
rc = rc.replace(old_early, old_early +
    "    # mainline kernel: binder lives in binderfs\n"
    "    mkdir /dev/binderfs 0755 root root\n"
    "    mount binder binder /dev/binderfs\n"
    "    chmod 0666 /dev/binderfs/binder\n"
    "    symlink /dev/binderfs/binder /dev/binder\n"
    "    # watchdog, boot deadline and logs (replaces watchdogd)\n"
    "    start station_wd\n")

old_wd = ("service watchdogd /sbin/watchdogd\n    class core\n    oneshot\n"
          "    seclabel u:r:watchdogd:s0\n")
assert rc.count(old_wd) == 1
rc = rc.replace(old_wd,
    "# mainline kernel: station_wd feeds the watchdog instead (boot deadline)\n"
    "service station_wd /sbin/station/busybox sh /sbin/station-android.sh\n"
    "    class core\n    user root\n    group root\n    seclabel u:r:init:s0\n")

body = b""
ino = 9000
for n, e in ents[:-1]:
    if n == "init.sun50iw1p1.rc":
        mode = int(e[14:22], 16)
        body += cpio_file(n, rc.encode(), ino, mode)
    else:
        body += e
    ino += 1
# own static busybox; it must be called "busybox" to accept "busybox sh"
body += cpio_file("sbin/station", b"", ino + 1, 0o040750)
body += cpio_file("sbin/station/busybox", open(busybox, "rb").read(), ino + 4, 0o100750)
body += cpio_file("sbin/station-android.sh", open(script, "rb").read().replace(b"\r\n", b"\n"),
                  ino + 2, 0o100750)
# rdinit=/station-init: kernel log mirror into misc, then exec /init
init_wrapper = script.replace("station-android.sh", "station-init.sh")
body += cpio_file("station-init", open(init_wrapper, "rb").read().replace(b"\r\n", b"\n"),
                  ino + 3, 0o100750)
body += cpio_file("TRAILER!!!", b"", 0, 0)
body += b"\0" * ((-len(body)) % 512)
if out.endswith(".xz"):
    import lzma  # kernels with only RD_XZ; the kernel wants the CRC32 check
    open(out, "wb").write(lzma.compress(body, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, preset=9))
else:
    open(out, "wb").write(gzip.compress(body, 9, mtime=0))
print(f"{out}: {len(ents)} vendor entries + busybox, station-android.sh, station-init, rc patched")
