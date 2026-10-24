# SPDX-License-Identifier: GPL-2.0
"""AOSP boot image, header version 0 (what the Station's vendor U-Boot "boota" reads)."""
import hashlib
import struct

HDR = "<8s10I16s512s32s1024s"


def parse(data):
    f = struct.unpack_from(HDR, data)
    h = dict(magic=f[0], kernel_size=f[1], kernel_addr=f[2], ramdisk_size=f[3], ramdisk_addr=f[4],
             second_size=f[5], second_addr=f[6], tags_addr=f[7], page_size=f[8], hdr_version=f[9],
             os_version=f[10], name=f[11], cmdline=f[12], id=f[13], extra=f[14])
    assert h["magic"] == b"ANDROID!"
    ps = h["page_size"]
    up = lambda n: (n + ps - 1) // ps * ps
    k0 = ps
    r0 = k0 + up(h["kernel_size"])
    s0 = r0 + up(h["ramdisk_size"])
    h["kernel"] = data[k0:k0 + h["kernel_size"]]
    h["ramdisk"] = data[r0:r0 + h["ramdisk_size"]]
    h["second"] = data[s0:s0 + h["second_size"]]
    return h


def build(h):
    ps = h["page_size"]
    pad = lambda b: b + b"\0" * ((-len(b)) % ps)
    sha = hashlib.sha1()
    for part in (h["kernel"], h["ramdisk"], h["second"]):
        sha.update(part)
        sha.update(struct.pack("<I", len(part)))
    hid = sha.digest().ljust(32, b"\0")
    hdr = struct.pack(HDR, b"ANDROID!", len(h["kernel"]), h["kernel_addr"], len(h["ramdisk"]), h["ramdisk_addr"],
                      len(h["second"]), h["second_addr"], h["tags_addr"], ps, h["hdr_version"], h["os_version"],
                      h["name"], h["cmdline"], hid, h["extra"])
    return pad(hdr) + pad(h["kernel"]) + pad(h["ramdisk"]) + (pad(h["second"]) if h["second"] else b"")
