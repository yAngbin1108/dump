#!/usr/bin/env python3
"""
chained_fixups_check.py — validate the chained-fixup chains of a Mach-O binary.

This is the check that none of the earlier structural inspections performed:
it actually *walks* every chain the way dyld does, using the stride implied by
the declared pointer_format, and reports anomalies that would make dyld bind
garbage or walk off the end of a page.

Usage: chained_fixups_check.py <macho> [<macho> ...]
"""
import struct
import sys

NONE = 0xFFFF
MULTI = 0x8000

FORMATS = {
    1:  ("DYLD_CHAINED_PTR_ARM64E", 4, 16),
    2:  ("DYLD_CHAINED_PTR_64", 4, 0),
    3:  ("DYLD_CHAINED_PTR_32", 4, 0),
    6:  ("DYLD_CHAINED_PTR_64_OFFSET", 4, 0),
    7:  ("DYLD_CHAINED_PTR_ARM64E_KERNEL", 4, 16),
    9:  ("DYLD_CHAINED_PTR_ARM64E_USERLAND", 8, 16),
    12: ("DYLD_CHAINED_PTR_ARM64E_USERLAND24", 8, 24),
}


def segments(d):
    n = struct.unpack_from('<I', d, 16)[0]
    off = 32
    segs = []
    chained = None
    for _ in range(n):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x19:                                   # LC_SEGMENT_64
            name = d[off+8:off+24].rstrip(b'\0').decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off+24)
            segs.append((name, vmaddr, vmsize, fileoff, filesize))
        elif cmd == 0x80000034:                           # LC_DYLD_CHAINED_FIXUPS
            chained = struct.unpack_from('<II', d, off + 8)
        off += size
    return segs, chained


def check(path):
    with open(path, 'rb') as fh:
        d = fh.read()
    magic, cputype, cpusubtype, _ = struct.unpack_from('<IIII', d, 0)
    print("=== %s ===" % path)
    if magic != 0xFEEDFACF:
        print("   not a 64-bit Mach-O"); return
    print("   cpusubtype=0x%08x" % cpusubtype)

    segs, chained = segments(d)
    if not chained:
        print("   no LC_DYLD_CHAINED_FIXUPS"); return

    base = chained[0]
    (version, starts_off, imports_off, symbols_off,
     imports_count, imports_format, symbols_format) = struct.unpack_from('<IIIIIII', d, base)
    starts = base + starts_off
    seg_count = struct.unpack_from('<I', d, starts)[0]

    problems = []
    total_ptrs = binds = rebases = authptrs = 0
    formats = []

    for si in range(seg_count):
        seg_off = struct.unpack_from('<I', d, starts + 4 + si * 4)[0]
        if seg_off == 0:
            continue
        s = starts + seg_off
        size, page_size, pointer_format, seg_vmaddr, max_valid, page_count = \
            struct.unpack_from('<IHHQIH', d, s)
        formats.append(pointer_format)

        info = FORMATS.get(pointer_format)
        if info is None:
            problems.append("segment %d: unknown pointer_format %d" % (si, pointer_format))
            continue
        fname, stride, ordinal_bits = info

        page_start = list(struct.unpack_from('<%dH' % page_count, d, s + 22))
        # Overflow table follows the page_start array.
        overflow_off = s + 22 + 2 * page_count

        def chain_offsets(page_index):
            """Byte offsets within the page of each chain head."""
            v = page_start[page_index]
            if v == NONE:
                return []
            if not (v & MULTI):
                return [v]
            # v & 0x7FFF is an index (in uint16 units) into the overflow table.
            idx = v & 0x7FFF
            heads = []
            while len(heads) < 4096:
                w = struct.unpack_from('<H', d, overflow_off + idx * 2)[0]
                heads.append(w)
                nxt_idx = struct.unpack_from('<H', d, overflow_off + (idx + 1) * 2)[0]
                if nxt_idx == MULTI:            # DYLD_CHAINED_PTR_START_LAST
                    break
                idx = nxt_idx
            return heads

        # Chain heads are offsets into the segment's *pages*, so the file
        # position is segment.fileoff + page*page_size + head — NOT relative to
        # the starts_in_segment struct, which lives in __LINKEDIT.
        seg_fileoff = segs[si][3] if si < len(segs) else 0
        for pi in range(page_count):
            for head in chain_offsets(pi):
                loc = seg_fileoff + pi * page_size + head
                page_end = seg_fileoff + (pi + 1) * page_size
                steps = 0
                while True:
                    steps += 1
                    if steps > 4096:
                        problems.append("seg %d page %d: chain longer than 4096 (cycle?)" % (si, pi))
                        break
                    if loc + 8 > len(d):
                        problems.append("seg %d page %d: chain runs past EOF" % (si, pi))
                        break
                    if loc >= page_end:
                        problems.append("seg %d page %d: chain left its page (stride mismatch?)" % (si, pi))
                        break
                    v = struct.unpack_from('<Q', d, loc)[0]
                    bind = (v >> 62) & 1
                    auth = (v >> 63) & 1
                    nxt = (v >> 51) & 0x7FF
                    total_ptrs += 1
                    if auth:
                        authptrs += 1
                    if bind:
                        binds += 1
                        ordinal = v & ((1 << ordinal_bits) - 1)
                        if ordinal >= imports_count:
                            problems.append(
                                "seg %d page %d @0x%x: bind ordinal %d >= imports_count %d"
                                % (si, pi, loc, ordinal, imports_count))
                        if ordinal_bits == 24:
                            zero = (v >> 24) & 0xFF
                            if zero != 0:
                                problems.append(
                                    "seg %d page %d @0x%x: 24-bit ordinal with non-zero upper byte 0x%x"
                                    % (si, pi, loc, zero))
                    else:
                        rebases += 1
                        if auth:
                            target = v & 0xFFFFFFFF
                        else:
                            target = (v & 0x7FFFFFFFFFF) | (((v >> 43) & 0xFF) << 56)
                        if target != 0:
                            ok = any(va <= target < va + vs and vs for _, va, vs, _, _ in segs)
                            if not ok:
                                problems.append(
                                    "seg %d page %d @0x%x: rebase target 0x%x outside all segments"
                                    % (si, pi, loc, target))
                    if nxt == 0:
                        break
                    loc += nxt * stride

    print("   pointer_format(s) = %s" % formats)
    print("   pointers=%d binds=%d rebases=%d auth=%d imports_count=%d"
          % (total_ptrs, binds, rebases, authptrs, imports_count))
    if problems:
        print("   !! %d PROBLEM(S):" % len(problems))
        for p in problems[:10]:
            print("      %s" % p)
    else:
        print("   OK — every chain walked cleanly with the declared stride")


if __name__ == '__main__':
    for p in sys.argv[1:]:
        check(p)
        print()
