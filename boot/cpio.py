# SPDX-License-Identifier: GPL-2.0
"""newc cpio archives (what the kernel unpacks as initramfs): read and write."""


def entry(name, mode, data=b"", ino=0, rdev=(0, 0), nlink=1):
    nb = name.encode() + b"\0"
    fields = (ino, mode, 0, 0, nlink, 0, len(data), 0, 0, rdev[0], rdev[1], len(nb), 0)
    b = b"070701" + b"".join(b"%08X" % v for v in fields) + nb
    b += b"\0" * ((-len(b)) % 4) + data
    return b + b"\0" * ((-len(b)) % 4)


def finish(body):
    """the archive: body + trailer, padded to 512 bytes as gen_init_cpio does"""
    out = bytes(body) + entry("TRAILER!!!", 0)
    return out + b"\0" * ((-len(out)) % 512)


def read(raw):
    """[(name, mode, data, raw_entry)] up to and without the trailer"""
    out, i = [], 0
    while True:
        assert raw[i:i + 6] == b"070701", f"not a newc archive at {i:#x}"
        f = [int(raw[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        mode, filesize, namesize = f[1], f[6], f[11]
        name = raw[i + 110:i + 110 + namesize - 1].decode()
        d0 = (i + 110 + namesize + 3) & ~3
        end = (d0 + filesize + 3) & ~3
        if name == "TRAILER!!!":
            return out
        out.append((name, mode, raw[d0:d0 + filesize], raw[i:end]))
        i = end
