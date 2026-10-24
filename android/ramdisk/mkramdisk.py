#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Ramdisk to run the Station's own Android 6 / Quasar on this kernel.

    mkramdisk.py --boot-img boot.img --busybox busybox --mali mali.ko \
                 --libion64 lib64/libion.so --libion32 lib/libion.so \
                 --hwcomposer lib64/hw/hwcomposer.drm.so -o android-ramdisk.cpio.gz

It is the vendor boot.img ramdisk with the smallest changes this kernel needs,
in init.rc, init.sun50iw1p1.rc and ueventd.sun50iw1p1.rc plus files under
/sbin/station;
/system is used as it is on the Station (some files are bind-mounted over,
nothing is written):
  - binder from binderfs (/dev/binder is a link; ueventd of Android 6 only
    knows the misc device, which binderfs kernels do not have);
  - station_wd (/sbin/station-android.sh) feeds the watchdog in place of the
    vendor watchdogd, keeps a boot deadline and logs to misc;
  - GPU: mali.ko (ARM r10p0 speaking the r6p0 interface of the vendor
    libGLES_mali), loaded at early-init;
  - ION: libion.so over DMA-BUF heaps (android/libion) in place of the
    vendor libion, whose kernel interface mainline does not have; the heaps
    are open to all, as /dev/ion was;
  - display: hwcomposer over DRM/KMS (android/hwcomposer) in place of
    hwcomposer.tulip, which drives the Allwinner display driver (/dev/disp);
    the vendor gralloc has no framebuffer HAL to fall back to.
  - flash_recovery is disabled: install-recovery.sh would put the stock
    recovery back over the mainline image there.
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
UEVENTD_RC = "ueventd.sun50iw1p1.rc"


def strace_service(rc, name):
    """debug builds: run one service under strace, the trace into /dev/station"""
    head = f"service {name} "
    i = rc.find(head)
    if i < 0:
        return None
    j = rc.index("\n", i)
    cmd = rc[i + len(head):j]
    return (rc[:i] + head + "/station-debug/strace -f -tt -s 96 -e trace=%file,%desc,%memory "
            f"-o /dev/station/{name}.strace " + cmd + rc[j:])


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
            "    # debug traces (mkramdisk.py --strace), read by station-init\n"
            "    mkdir /dev/station 0777 root root\n"
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
           "on post-fs\n"
           "    mount none /sbin/station/libion64.so /system/lib64/libion.so bind\n"
           "    mount none /sbin/station/libion32.so /system/lib/libion.so bind\n"
           "    mount none /sbin/station/hwcomposer.drm.so /system/lib64/hw/hwcomposer.tulip.so bind\n"
           "    # SurfaceFlinger is 64-bit; nothing 32-bit may load the vendor one\n"
           "    mount none /sbin/station/empty /system/lib/hw/hwcomposer.tulip.so bind\n")
    return rc


def patch_init_rc(rc):
    """init.rc: never let Android rewrite the recovery partition"""
    old = "service flash_recovery /system/bin/install-recovery.sh
    class main
    oneshot
"
    assert rc.count(old) == 1, old
    # install-recovery.sh puts the stock recovery back when its hash differs,
    # and the mainline image lives there
    return rc.replace(old, old + "    disabled
")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("boot-img", "busybox", "mali", "libion64", "libion32", "hwcomposer"):
        ap.add_argument("--" + name, required=True)
    ap.add_argument("--strace", nargs=2, metavar=("STRACE", "SERVICE"),
                    help="debug: run SERVICE under this static strace")
    ap.add_argument("-o", "--output", required=True, help=".cpio.gz or .cpio.xz")
    a = ap.parse_args()

    h = bootimg.parse(open(a.boot_img, "rb").read())
    ents = cpio.read(gzip.decompress(h["ramdisk"]))
    names = [e[0] for e in ents]
    assert RC in names and not any(n.startswith("sbin/station") for n in names), "not a vendor ramdisk"

    lf = lambda p: open(p, "rb").read().replace(b"\r\n", b"\n")
    body, ino = bytearray(), 9000
    traced = False
    for name, mode, data, raw in ents:
        text = None
        if name == RC:
            text = patch_rc(data.decode())
        elif name == "init.rc":
            text = patch_init_rc(data.decode())
        elif name == UEVENTD_RC:
            text = data.decode().rstrip("\n") + (
                "\n# mainline kernel: ION is DMA-BUF heaps (android/libion); their nodes\n"
                "# are dma_heap/<heap> (DEVNAME), not the /dev/<heap> ueventd would make\n"
                "subsystem dma_heap\n"
                "\tdevname uevent_devname\n"
                "\tdirname /dev\n\n"
                "/dev/dma_heap/*            0666    system      graphics\n")
        if a.strace and name.endswith(".rc"):
            t = strace_service(text if text is not None else data.decode(), a.strace[1])
            if t is not None:
                text, traced = t, True
        body += cpio.entry(name, mode, text.encode(), ino) if text is not None else raw
        ino += 1
    assert not a.strace or traced, f"service {a.strace[1]} not found"
    add = [
        ("sbin/station", 0o040755, b""),
        # it must be called "busybox" to accept "busybox sh"
        ("sbin/station/busybox", 0o100750, open(a.busybox, "rb").read()),
        ("sbin/station/mali.ko", 0o100640, open(a.mali, "rb").read()),
        ("sbin/station/libion64.so", 0o100644, open(a.libion64, "rb").read()),
        ("sbin/station/libion32.so", 0o100644, open(a.libion32, "rb").read()),
        ("sbin/station/hwcomposer.drm.so", 0o100644, open(a.hwcomposer, "rb").read()),
        ("sbin/station/empty", 0o100644, b""),
        ("sbin/station-android.sh", 0o100750, lf(os.path.join(HERE, "station-android.sh"))),
        ("station-init", 0o100750, lf(os.path.join(HERE, "station-init.sh"))),
    ]
    if a.strace:
        # not under /sbin: that is 0750 on Android 6, closed to the service users
        add.append(("station-debug", 0o040755, b""))
        add.append(("station-debug/strace", 0o100755, open(a.strace[0], "rb").read()))
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
