#!/usr/bin/env python3
"""
fix_chained_ptr_format.py — rewrite a Mach-O's chained-fixup pointer_format
from DYLD_CHAINED_PTR_ARM64E (1, stride 4) to DYLD_CHAINED_PTR_ARM64E_USERLAND24
(12, stride 8) in every dyld_chained_starts_in_segment.

Why: theos's ld64-609 encodes arm64e fixup chains with a stride of 8 (its own
consistency check is `next * 8 == delta`) but stamps the segment header with
pointer_format 1, which dyld walks with a stride of 4. The chains are therefore
read at the wrong offset and dyld binds garbage — the process dies during load.

The rewrite is bit-exact for fewer than 65536 imports: the only layout
difference between the two formats is that bind.ordinal widens from 16 to 24
bits while bind.zero narrows from 16 to 8 (same for auth_bind), so every pointer
keeps the same bit pattern.

Handles both thin and fat Mach-O files (fat is rewritten in place, slice by
slice, preserving the fat header).

Usage: fix_chained_ptr_format.py <macho> [<macho> ...]
"""
import struct
import sys

WANT = 12
OLD = 1


def patch_slice(d, base, label):
    """Patch one Mach-O image located at `base` inside bytearray `d`."""
    magic = struct.unpack_from('<I', d, base)[0]
    if magic != 0xFEEDFACF:
        return 0
    cputype, cpusubtype = struct.unpack_from('<II', d, base + 4)
    ncmds = struct.unpack_from('<I', d, base + 16)[0]
    off = base + 32
    fixups = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x80000034:                       # LC_DYLD_CHAINED_FIXUPS
            fixups = struct.unpack_from('<II', d, off + 8)
        off += size

    tag = 'arm64e' if (cpusubtype & 0xFFFFFF) == 2 else 'arm64'
    if fixups is None:
        print("     %-10s %s: no chained fixups" % (label, tag))
        return 0

    fx = base + fixups[0]
    starts_off, imports_count = struct.unpack_from('<I', d, fx + 4)[0], \
                                struct.unpack_from('<I', d, fx + 16)[0]
    starts = fx + starts_off
    seg_count = struct.unpack_from('<I', d, starts)[0]

    if imports_count >= 65536:
        sys.exit("%s: %d imports — the 1->12 rewrite is NOT bit-exact, aborting"
                 % (label, imports_count))

    patched = 0
    formats = []
    for i in range(seg_count):
        seg_off = struct.unpack_from('<I', d, starts + 4 + i * 4)[0]
        if seg_off == 0:
            continue
        seg = starts + seg_off
        fmt = struct.unpack_from('<H', d, seg + 6)[0]
        formats.append(fmt)
        if fmt == OLD:
            struct.pack_into('<H', d, seg + 6, WANT)
            patched += 1

    print("     %-10s %s: pointer_format %s -> %d segment(s) rewritten"
          % (label, tag, formats, patched))
    return patched


def main(path):
    with open(path, 'rb') as fh:
        d = bytearray(fh.read())

    magic = struct.unpack_from('>I', d, 0)[0]
    total = 0
    if magic == 0xCAFEBABE:                          # fat
        n = struct.unpack_from('>I', d, 4)[0]
        for i in range(n):
            off = 8 + i * 20
            _ct, _cs, slice_off, slice_size, _al = struct.unpack_from('>IIIII', d, off)
            total += patch_slice(d, slice_off, "slice%d" % i)
    else:
        total += patch_slice(d, 0, "thin")

    if total == 0:
        print("  %s: nothing to do" % path)
        return
    with open(path, 'wb') as fh:
        fh.write(d)
    print("  %s: %d segment header(s) fixed" % (path, total))


if __name__ == '__main__':
    for p in sys.argv[1:]:
        main(p)
