#!/usr/bin/env python3
"""
to_userland24.py — convert an arm64e chained-fixup table from
DYLD_CHAINED_PTR_ARM64E (1) to DYLD_CHAINED_PTR_ARM64E_USERLAND24 (12).

Why
---
ld64-609 — the only linker available here — always writes pointer_format 1.
Every arm64e binary Apple ships uses 12, and the two formats do not agree on
what a rebase's `target` field means:

    format 1   target = absolute, unslid vmaddr
    format 12  target = offset from the image base  (dyld adds the base)

Feeding format-1 tables to a loader that expects USERLAND24 semantics hands it
addresses in the wrong space, which shows up as pointers with the top half
cleared (e.g. 0xdac11950) and a SIGBUS inside the first objc_msgSend.

Binds are compatible: both formats keep the low bits of the ordinal in the same
place, and everything this project links has fewer than 65536 imports, so
`ordinal:16, zero:16` reads back identically through `ordinal:24, zero:8` when
`zero` is 0 — verified on the produced table before the rewrite is applied.

Usage: to_userland24.py <arm64e-macho> [--verbose]
Runs after linking and before authify_objc.py (which then sees format 12 and
keeps every rebase target as an offset).
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_DYLD_CHAINED_FIXUPS = 0x80000034
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2

BIND_BIT = 62
AUTH_BIT = 63
NEXT_SHIFT = 51
NEXT_MASK = 0x7FF
TARGET_MASK = (1 << 43) - 1

FMT_ARM64E = 1
FMT_USERLAND24 = 12


def die(msg):
    sys.exit("to_userland24: " + msg)


def main(path, verbose=False):
    d = bytearray(open(path, 'rb').read())
    magic, cputype, cpusubtype = struct.unpack_from('<III', d, 0)
    if magic != MH_MAGIC_64:
        die("%s is not a 64-bit Mach-O" % path)
    if cputype != CPU_TYPE_ARM64 or (cpusubtype & 0xFFFFFF) != CPU_SUBTYPE_ARM64E:
        die("%s is not arm64e" % path)

    segs = []
    chained = None
    ncmds = struct.unpack_from('<I', d, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == LC_SEGMENT_64:
            name = d[off + 8:off + 24].rstrip(b'\0').decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off + 24)
            segs.append((name, vmaddr, vmsize, fileoff, filesize))
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            chained = struct.unpack_from('<II', d, off + 8)
        off += size
    if not chained:
        die("no LC_DYLD_CHAINED_FIXUPS")

    base_vm = None
    for name, vmaddr, _, _, _ in segs:
        if name == '__TEXT':
            base_vm = vmaddr
    if base_vm is None:
        die("no __TEXT")

    base = chained[0]
    (version, starts, imports, symbols, icount,
     ifmt, symfmt) = struct.unpack_from('<IIIIHBB', d, base)
    if version != 0:
        die("unknown chained-fixups version %d" % version)

    segcount = struct.unpack_from('<I', d, base + starts)[0]
    formats = set()
    seginfo = []
    for si in range(segcount):
        (so,) = struct.unpack_from('<I', d, base + starts + 4 + 4 * si)
        if not so:
            seginfo.append(None)
            continue
        p = base + starts + so
        (size, page_size, pfmt, seg_off,
         max_valid, page_count) = struct.unpack_from('<IHHQIH', d, p)
        formats.add(pfmt)
        seginfo.append((p, page_size, pfmt, page_count))

    if formats == {FMT_USERLAND24}:
        print("    already USERLAND24, nothing to convert")
        return 0
    if formats != {FMT_ARM64E}:
        die("mixed or unexpected pointer formats %s" % sorted(formats))

    # Binds are only interchangeable while every ordinal fits 16 bits and the
    # zero field is unused; check that before touching anything.
    rebases = 0
    for si, info in enumerate(seginfo):
        if not info:
            continue
        p, page_size, pfmt, page_count = info
        segstart = segs[si][3]
        segvm = segs[si][1]
        page_start = struct.unpack_from('<%dH' % page_count, d, p + 22)
        for pi in range(page_count):
            if page_start[pi] == 0xFFFF:
                continue
            loc = segstart + pi * page_size + page_start[pi]
            for _ in range(20000):
                word = struct.unpack_from('<Q', d, loc)[0]
                if (word >> BIND_BIT) & 1:
                    if (word >> 16) & 0xFFFF:
                        die("bind with a non-zero zero field at %#x — the "
                            "16/24-bit ordinal conversion is not safe here" % loc)
                    if (word & 0xFFFF) >= icount:
                        die("bind ordinal out of range at %#x" % loc)
                elif (word >> AUTH_BIT) & 1:
                    pass    # auth rebases already carry an offset
                else:
                    target = word & TARGET_MASK
                    high8 = (word >> 43) & 0xFF
                    absolute = target + (high8 << 56)
                    rel = absolute - base_vm
                    if rel < 0 or rel >= (1 << 43):
                        die("rebase at %#x points outside the image (0x%x)"
                            % (loc, absolute))
                    word = (rel & TARGET_MASK) | (word & ~TARGET_MASK)
                    struct.pack_into('<Q', d, loc, word)
                    rebases += 1
                nxt = (word >> NEXT_SHIFT) & NEXT_MASK
                if nxt == 0:
                    break
                loc += nxt * 8

    # Rewrite the declared format last, so a failure above leaves the file alone.
    for info in seginfo:
        if not info:
            continue
        p = info[0]
        struct.pack_into('<H', d, p + 6, FMT_USERLAND24)

    open(path, 'wb').write(d)
    print("    pointer_format 1 -> 12 (USERLAND24), %d rebase targets made "
          "base-relative, %d imports (15-bit safe)" % (rebases, icount))
    return rebases or 1


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not args:
        sys.exit(__doc__)
    rc = 0
    for p in args:
        print("==> to_userland24 %s" % p)
        rc |= main(p, verbose=('-v' in sys.argv or '--verbose' in sys.argv))
    sys.exit(0 if rc else 1)
