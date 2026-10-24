#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Ramdisk to run the Station's own Android 6 / Quasar on this kernel.

    mkramdisk.py --boot-img boot.img --busybox busybox --mali mali.ko \
                 --libion64 lib64/libion.so --libion32 lib/libion.so -o android-ramdisk.cpio.gz

It is the vendor boot.img ramdisk with the smallest changes this kernel needs,
all in init.sun50iw1p1.rc plus files under /sbin/station; /system is used as
it is on the Station (some files are bind-mounted over, nothing is written):
  - binder from binderfs (/dev/binder is a link; ueventd of Android 6 only
    knows the misc device, which binderfs kernels do not have);
  - station_wd (/sbin/station-android.sh) feeds the watchdog in place of the
    vendor watchdogd, keeps a boot deadline and logs to misc;
  - GPU: mali.ko (ARM r10p0 speaking the r6p0 interface of the vendor
    libGLES_mali), loaded at early-init;
  - ION: libion.so over DMA-BUF heaps (android/libion) in place of the
    vendor libion, whose kernel interface mainline does not have;
  - no hwcomposer: hwcomposer.tulip needs the Allwinner display driver
    (/dev/disp); without it SurfaceFlinger posts through the framebuffer HAL
    of gralloc on /dev/graphics/fb0 (DRM fbdev emulation).
rdinit=/station-init mirrors the kernel log into misc, then runs /init.
"""
import argparse
import gzip
import lzma
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "boot"))
import bootimg  # noqa: E402
import cpio  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RC = "init.sun50iw1p1.rc"


def patch_rc(rc):
    def replace(old, new):
        nonlocal rc
        assert rc.count(old) == 1, old
        rc = rc.replace(old, new)

    early = "on early-init\n    mount debugfs debugfs /sys/kernel/debug/ mode=755\n"
    replace(early, early +
            "    # mainline kernel: binder lives in binderfs\n"
            "    mkdir /dev/binderfs 0755 root root\n"
            "    mount binder binder /dev/binderfs\n"
            "    chmod 0666 /dev/binderfs/binder\n"
            "    symlink /dev/binderfs/binder /dev/binder\n"
            "    # GPU driver for the vendor libGLES_mali\n"
            "    insmod /sbin/station/mali.ko\n"
            "    # watchdog, boot deadline and logs (replaces watchdogd)\n"
            "    start station_wd\n")
    replace("service watchdogd /sbin/watchdogd\n    class core\n    oneshot\n"
            "    seclabel u:r:watchdogd:s0\n",
            "# mainline kernel: station_wd feeds the watchdog instead (boot deadline)\n"
            "service station_wd /sbin/station/busybox sh /sbin/station-android.sh\n"
            "    class core\n    user root\n    group root\n    seclabel u:r:init:s0\n")
    rc += ("\n# mainline kernel: ION from DMA-BUF heaps, no Allwinner display driver\n"
           "on init\n"
           "    chmod 0666 /dev/dma_heap/system\n\n"
           "on post-fs\n"
           "    mount none /sbin/station/libion64.so /system/lib64/libion.so bind\n"
           "    mount none /sbin/station/libion32.so /system/lib/libion.so bind\n"
           "    mount none /sbin/station/empty /system/lib64/hw/hwcomposer.tulip.so bind\n"
           "    mount none /sbin/station/empty /system/lib/hw/hwcomposer.tulip.so bind\n")
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("boot-img", "busybox", "mali", "libion64", "libion32"):
        ap.add_argument("--" + name, required=True)
    ap.add_argument("-o", "--output", required=True, help=".cpio.gz or .cpio.xz")
    a = ap.parse_args()

    h = bootimg.parse(open(a.boot_img, "rb").read())
    ents = cpio.read(gzip.decompress(h["ramdisk"]))
    names = [e[0] for e in ents]
    assert RC in names and not any(n.startswith("sbin/station") for n in names), "not a vendor ramdisk"

    lf = lambda p: open(p, "rb").read().replace(b"\r\n", b"\n")
    body, ino = bytearray(), 9000
    for name, mode, data, raw in ents:
        body += cpio.entry(name, mode, patch_rc(data.decode()).encode(), ino) if name == RC else raw
        ino += 1
    add = [
        ("sbin/station", 0o040750, b""),
        # it must be called "busybox" to accept "busybox sh"
        ("sbin/station/busybox", 0o100750, open(a.busybox, "rb").read()),
        ("sbin/station/mali.ko", 0o100640, open(a.mali, "rb").read()),
        ("sbin/station/libion64.so", 0o100644, open(a.libion64, "rb").read()),
        ("sbin/station/libion32.so", 0o100644, open(a.libion32, "rb").read()),
        ("sbin/station/empty", 0o100644, b""),
        ("sbin/station-android.sh", 0o100750, lf(os.path.join(HERE, "station-android.sh"))),
        ("station-init", 0o100750, lf(os.path.join(HERE, "station-init.sh"))),
    ]
    for name, mode, data in add:
        ino += 1
        body += cpio.entry(name, mode, data, ino)
    out = cpio.finish(body)

    if a.output.endswith(".xz"):
        # the kernel's xz decoder wants the CRC32 check
        data = lzma.compress(out, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, preset=9)
    else:
        data = gzip.compress(out, 9, mtime=0)
    open(a.output, "wb").write(data)
    print(f"{a.output}: {len(ents)} vendor entries, {RC} patched, +{len(add)} station entries, {len(data)} bytes")


if __name__ == "__main__":
    main()
