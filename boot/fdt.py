# SPDX-License-Identifier: GPL-2.0
"""Minimal flattened device tree editor: set properties of one node.

Enough for boot/pack.py, which points /chosen at the initramfs; pure Python,
so an image can be packed on any OS without dtc/libfdt.
"""
import struct

MAGIC = 0xd00dfeed
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9
HDR = ">10I"            # magic .. size_dt_struct (version 17 header)


def _align4(n):
    return (n + 3) & ~3


def set_props(blob, path, props):
    """Return blob with node `path` (e.g. "/chosen") holding `props` ({name: bytes});
    existing properties of those names are replaced, the node must exist."""
    (magic, _total, off_struct, off_strings, off_rsv, version, last_comp,
     boot_cpu, size_strings, size_struct) = struct.unpack_from(HDR, blob)
    assert magic == MAGIC and version >= 17 and last_comp <= 16, "not an FDT v17"
    strings = bytearray(blob[off_strings:off_strings + size_strings])
    rsv = blob[off_rsv:off_struct]
    st = blob[off_struct:off_struct + size_struct]

    def stroff(name):
        key = name.encode() + b"\0"
        i = strings.find(key)
        while i > 0 and strings[i - 1] != 0:      # match whole strings only
            i = strings.find(key, i + 1)
        if i < 0:
            i = len(strings)
            strings.extend(key)
        return i

    want = [p for p in path.strip("/").split("/") if p]
    out = bytearray()
    stack, done, i = [], False, 0
    while True:
        tok, = struct.unpack_from(">I", st, i)
        if tok == BEGIN_NODE:
            j = st.index(b"\0", i + 4)
            name = st[i + 4:j].decode()
            nxt = _align4(j + 1)
            out += st[i:nxt]
            stack.append(name)
            i = nxt
            if stack[1:] == want:
                for k, v in props.items():
                    out += struct.pack(">III", PROP, len(v), stroff(k)) + v + b"\0" * (_align4(len(v)) - len(v))
                done = True
        elif tok == PROP:
            ln, no = struct.unpack_from(">II", st, i + 4)
            nxt = _align4(i + 12 + ln)
            name = strings[no:strings.index(b"\0", no)].decode()
            if not (stack[1:] == want and name in props):
                out += st[i:nxt]
            i = nxt
        elif tok == END_NODE:
            stack.pop()
            out += st[i:i + 4]
            i += 4
        elif tok == NOP:
            i += 4
        elif tok == END:
            out += st[i:i + 4]
            break
        else:
            raise ValueError(f"bad FDT token {tok:#x} at {i:#x}")
    if not done:
        raise KeyError(f"node {path} not in the DTB")
    off_rsv = 40                                  # 8-aligned; entries are 16 bytes
    off_struct = off_rsv + len(rsv)
    off_strings = off_struct + len(out)
    total = off_strings + len(strings)
    hdr = struct.pack(HDR, MAGIC, total, off_struct, off_strings, off_rsv, 17, 16,
                      boot_cpu, len(strings), len(out))
    return hdr + rsv + bytes(out) + bytes(strings)


def get_prop(blob, path, name):
    """Value of one property, or None (used by the self-checks in pack.py)."""
    (magic, _t, off_struct, off_strings, _r, _v, _l, _b, size_strings, size_struct) = struct.unpack_from(HDR, blob)
    assert magic == MAGIC
    st = blob[off_struct:off_struct + size_struct]
    strings = blob[off_strings:off_strings + size_strings]
    want = [p for p in path.strip("/").split("/") if p]
    stack, i = [], 0
    while True:
        tok, = struct.unpack_from(">I", st, i)
        if tok == BEGIN_NODE:
            j = st.index(b"\0", i + 4)
            stack.append(st[i + 4:j].decode())
            i = _align4(j + 1)
        elif tok == PROP:
            ln, no = struct.unpack_from(">II", st, i + 4)
            if stack[1:] == want and strings[no:strings.index(b"\0", no)].decode() == name:
                return st[i + 12:i + 12 + ln]
            i = _align4(i + 12 + ln)
        elif tok == END_NODE:
            stack.pop()
            i += 4
        elif tok == NOP:
            i += 4
        elif tok == END:
            return None
        else:
            raise ValueError(f"bad FDT token {tok:#x}")
