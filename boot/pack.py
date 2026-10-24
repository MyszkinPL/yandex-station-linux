#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Pack Image + DTB (+ initramfs) into a recovery image for the Yandex Station 1.

    pack.py --shim shim.bin --image Image --dtb station.dtb \
            [--initramfs initramfs.list|initramfs.cpio[.gz]] [-D NAME=dir ...] -o recovery.img

Vendor U-Boot "boota" reads the whole boot image to 0x4007f800 and jumps to
the "kernel" part in place at 0x40080000. That part is our payload:

    0x000000  shim.bin (boot/shim.S): watchdog, DE2 routing, Wi-Fi VDDIO, DTB swap
    0x010000  DTB             copied by the shim to 0x4e000000
    0x180000  Image           runs at 0x40200000 (2 MiB aligned, text_offset 0)
    after the kernel's image_size (BSS included): the initramfs, which the
              DTB's /chosen linux,initrd-start/-end point at

boota also copies the header's ramdisk to ramdisk_addr. That one is a 50-byte
empty archive placed in the shim log page (0x4e400000, no-map in the DTS),
so it can never land on anything we use. Pure Python, runs on any OS.
"""
import argparse
import gzip
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bootimg  # noqa: E402
import fdt  # noqa: E402

LOAD = 0x40080000           # where boota runs the payload
DTB_OFF = 0x10000
IMAGE_OFF = 0x180000
ATF = 0x48000000            # BL31 region: nothing of ours may reach it
SHIMLOG_RAMDISK = 0x4e400800
MAX_IMAGE = 32 << 20        # recovery partition
MARKER = b"STATIONSHIMLIT01"


def align(n, a):
    return (n + a - 1) // a * a


def cpio_entry(name, mode, data=b"", ino=0, rdev=(0, 0), nlink=1):
    nb = name.encode() + b"\0"
    fields = (ino, mode, 0, 0, nlink, 0, len(data), 0, 0, rdev[0], rdev[1], len(nb), 0)
    b = b"070701" + b"".join(b"%08X" % v for v in fields) + nb
    b += b"\0" * ((-len(b)) % 4) + data
    return b + b"\0" * ((-len(b)) % 4)


def cpio_from_list(path, defs):
    """gen_init_cpio list format (dir/file/nod/slink), ${NAME} from -D, paths relative to the list"""
    base = os.path.dirname(os.path.abspath(path))
    out, ino = bytearray(), 300
    for ln, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        line = re.sub(r"\$\{(\w+)\}", lambda m: defs[m.group(1)], line)
        w = line.split()
        kind, name = w[0], w[1].lstrip("/")
        ino += 1
        if kind == "dir":
            out += cpio_entry(name, 0o040000 | int(w[2], 8), ino=ino, nlink=2)
        elif kind == "file":
            src = w[2] if os.path.isabs(w[2]) else os.path.join(base, w[2])
            out += cpio_entry(name, 0o100000 | int(w[3], 8), open(src, "rb").read(), ino=ino)
        elif kind == "nod":
            t = {"c": 0o020000, "b": 0o060000}[w[5]]
            out += cpio_entry(name, t | int(w[2], 8), ino=ino, rdev=(int(w[6]), int(w[7])))
        elif kind == "slink":
            out += cpio_entry(name, 0o120000 | int(w[3], 8), w[2].encode(), ino=ino)
        else:
            sys.exit(f"{path}:{ln}: unknown entry {kind}")
    out += cpio_entry("TRAILER!!!", 0)
    return bytes(out) + b"\0" * ((-len(out)) % 512)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--shim", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--dtb", required=True)
    ap.add_argument("--initramfs", help="gen_init_cpio list, or a ready cpio (.gz)")
    ap.add_argument("-D", action="append", default=[], metavar="NAME=DIR", help="${NAME} in the list")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()

    shim = bytearray(open(a.shim, "rb").read())
    img = open(a.image, "rb").read()
    dtb = open(a.dtb, "rb").read()

    _, _, toff, isz, _ = struct.unpack_from("<IIQQQ", img, 0)
    assert img[0x38:0x3c] == b"ARM\x64" and toff == 0, "not an arm64 Image with text_offset 0"
    assert (LOAD + IMAGE_OFF) % (2 << 20) == 0, "the shim would have to move the Image"
    assert shim[0x38:0x3c] == b"ARM\x64" and len(shim) <= DTB_OFF, "shim.bin"
    lit = shim.find(MARKER)
    assert lit > 0 and shim.find(MARKER, lit + 1) < 0, "shim literals marker"
    lit += len(MARKER)
    assert struct.unpack_from("<Q", shim, lit + 8)[0] == IMAGE_OFF, "shim image_off"

    initrd = b""
    if a.initramfs:
        raw = open(a.initramfs, "rb").read()
        if raw[:6] == b"070701" or raw[:2] == b"\x1f\x8b" or raw[:6] == b"\xfd7zXZ\0":
            initrd = raw
        else:
            # -D paths are relative to where pack.py is run, list paths to the list
            defs = {k: os.path.abspath(v) for k, v in (d.split("=", 1) for d in a.D)}
            initrd = gzip.compress(cpio_from_list(a.initramfs, defs), 9, mtime=0)

    initrd_off = align(IMAGE_OFF + max(isz, len(img)), 1 << 16)
    if initrd:
        start = LOAD + initrd_off
        dtb = fdt.set_props(dtb, "/chosen", {
            "linux,initrd-start": struct.pack(">Q", start),
            "linux,initrd-end": struct.pack(">Q", start + len(initrd)),
        })
    dtb += b"\0" * ((-len(dtb)) % 16)
    assert DTB_OFF + len(dtb) <= IMAGE_OFF, "DTB too large"
    img16 = img + b"\0" * ((-len(img)) % 16)

    struct.pack_into("<QQQ", shim, lit, len(dtb), IMAGE_OFF, len(img16))
    pay = bytearray(shim.ljust(DTB_OFF, b"\0"))
    pay += dtb.ljust(IMAGE_OFF - DTB_OFF, b"\0")
    pay += img16
    if initrd:
        pay += b"\0" * (initrd_off - len(pay)) + initrd
    pay += b"\0" * ((-len(pay)) % 16)
    struct.pack_into("<Q", pay, 16, len(pay))          # shim header image_size

    assert LOAD + IMAGE_OFF + isz < ATF, "kernel would reach the ATF region"
    assert LOAD + len(pay) + 4096 < ATF, "payload would reach the ATF region"
    if initrd:
        assert pay[initrd_off:initrd_off + len(initrd)] == initrd
        assert initrd_off >= IMAGE_OFF + isz, "initramfs inside the kernel's BSS"
        assert fdt.get_prop(dtb, "/chosen", "linux,initrd-start") == struct.pack(">Q", LOAD + initrd_off)
    assert pay[DTB_OFF:DTB_OFF + len(dtb)] == dtb and pay[IMAGE_OFF:IMAGE_OFF + len(img)] == img

    empty = cpio_entry("TRAILER!!!", 0)
    empty += b"\0" * ((-len(empty)) % 512)
    h = dict(kernel=bytes(pay), ramdisk=gzip.compress(empty, 9, mtime=0), second=b"",
             kernel_addr=LOAD, ramdisk_addr=SHIMLOG_RAMDISK, second_addr=0x40f00000, tags_addr=0x40000100,
             page_size=2048, hdr_version=0, os_version=0, name=b"", cmdline=b"", extra=b"")
    out = bootimg.build(h)
    h2 = bootimg.parse(out)
    assert h2["kernel"] == pay and h2["kernel_addr"] == LOAD and len(out) <= MAX_IMAGE, "image too large"
    assert h2["ramdisk_addr"] == SHIMLOG_RAMDISK and len(h2["ramdisk"]) <= 0x800, \
        "the dummy ramdisk must stay in the shim log page"
    open(a.output, "wb").write(out)
    r = f", initramfs {LOAD + initrd_off:#x}+{len(initrd):#x}" if initrd else ""
    print(f"OK {a.output}: {len(out)} bytes, kernel {LOAD + IMAGE_OFF:#x}..{LOAD + IMAGE_OFF + isz:#x}{r}")


if __name__ == "__main__":
    main()
