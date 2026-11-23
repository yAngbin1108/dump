#!/usr/bin/env python3
"""
chained_ptr_stats.py — per-section statistics of a Mach-O's chained pointers.

Walks the chained fixups exactly like dyld (correct file addressing, correct
stride for the declared pointer_format) and groups every pointer by the section
it lives in and by what kind of pointer it is:

    rebase        plain rebase
    auth_rebase   authenticated rebase  (key, diversity, addrDiv)
    bind          plain bind
    auth_bind     authenticated bind    (key, diversity, addrDiv)

The point is to compare a build against a known-good binary produced by Apple's
toolchain: for arm64e the *keys* used for Objective-C metadata (isa, class
data, method lists) are part of the ABI, so a mismatch there is a real defect
even when the chains walk cleanly.

Usage: chained_ptr_stats.py <macho> [<macho> ...]
"""
import struct
import sys
from collections import Counter, defaultdict

NONE = 0xFFFF
MULTI = 0x8000

FORMATS = {
    1:  ("DYLD_CHAINED_PTR_ARM64E", 4, 16),
    2:  ("DYLD_CHAINED_PTR_64", 4, 0),
    6:  ("DYLD_CHAINED_PTR_64_OFFSET", 4, 0),
    7:  ("DYLD_CHAINED_PTR_ARM64E_KERNEL", 4, 16),
    9:  ("DYLD_CHAINED_PTR_ARM64E_USERLAND", 8, 16),
    12: ("DYLD_CHAINED_PTR_ARM64E_USERLAND24", 8, 24),
}

KEYNAMES = {0: "IA", 1: "IB", 2: "DA", 3: "DB"}


def load(path):
    with open(path, 'rb') as fh:
        return fh.read()


def segments_and_sections(d):
    n = struct.unpack_from('<I', d, 16)[0]
    off = 32
    segs = []
    secs = []          # (segname, sectname, addr, size, fileoff)
    chained = None
    for _ in range(n):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x19:
            seg = d[off+8:off+24].rstrip(b'\0').decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', d, off+24)
            segs.append((seg, vmaddr, vmsize, fileoff, filesize))
            ns = struct.unpack_from('<I', d, off+64)[0]
            so = off + 72
            for _ in range(ns):
                sn = d[so:so+16].rstrip(b'\0').decode()
                addr, sz, fo = struct.unpack_from('<QQI', d, so+32)
                secs.append((seg, sn, addr, sz, fo))
                so += 80
        elif cmd == 0x80000034:
            chained = struct.unpack_from('<II', d, off+8)
        off += size
    return segs, secs, chained


def section_for(secs, fileoff):
    for seg, sn, addr, size, fo in secs:
        if size and fo <= fileoff < fo + size:
            return "%s,%s" % (seg, sn)
    return "(unknown)"


def analyse(path):
    d = load(path)
    magic, cputype, cpusubtype, _ = struct.unpack_from('<IIII', d, 0)
    print("=== %s ===" % path)
    print("   cpusubtype=0x%08x" % cpusubtype)

    segs, secs, chained = segments_and_sections(d)
    if not chained:
        print("   no chained fixups")
        return

    base = chained[0]
    (version, starts_off, imports_off, symbols_off,
     imports_count, imports_format, symbols_format) = struct.unpack_from('<IIIIIII', d, base)
    starts = base + starts_off
    seg_count = struct.unpack_from('<I', d, starts)[0]

    per_section = defaultdict(Counter)

    for si in range(seg_count):
        seg_off = struct.unpack_from('<I', d, starts + 4 + si*4)[0]
        if seg_off == 0:
            continue
        s = starts + seg_off
        size, page_size, pointer_format, seg_vmaddr, max_valid, page_count = \
            struct.unpack_from('<IHHQIH', d, s)
        info = FORMATS.get(pointer_format)
        if info is None:
            continue
        _, stride, ordinal_bits = info

        page_start = list(struct.unpack_from('<%dH' % page_count, d, s + 22))
        overflow_off = s + 22 + 2*page_count
        seg_fileoff = segs[si][3] if si < len(segs) else 0

        def heads(pi):
            v = page_start[pi]
            if v == NONE:
                return []
            if not (v & MULTI):
                return [v]
            idx = v & 0x7FFF
            out = []
            while len(out) < 4096:
                out.append(struct.unpack_from('<H', d, overflow_off + idx*2)[0])
                nxt = struct.unpack_from('<H', d, overflow_off + (idx+1)*2)[0]
                if nxt == MULTI:
                    break
                idx = nxt
            return out

        for pi in range(page_count):
            for head in heads(pi):
                loc = seg_fileoff + pi*page_size + head
                page_end = seg_fileoff + (pi+1)*page_size
                steps = 0
                while steps < 4096 and loc + 8 <= len(d) and loc < page_end:
                    steps += 1
                    v = struct.unpack_from('<Q', d, loc)[0]
                    bind = (v >> 62) & 1
                    auth = (v >> 63) & 1
                    nxt = (v >> 51) & 0x7FF
                    secname = section_for(secs, loc)
                    if bind:
                        kind = "auth_bind" if auth else "bind"
                        if auth:
                            div = (v >> 32) & 0xFFFF
                            ad = (v >> 48) & 1
                            key = (v >> 49) & 3
                            per_section[secname][(kind, KEYNAMES[key], ad)] += 1
                        else:
                            per_section[secname][(kind,)] += 1
                    else:
                        if auth:
                            div = (v >> 32) & 0xFFFF
                            ad = (v >> 48) & 1
                            key = (v >> 49) & 3
                            per_section[secname][("auth_rebase", KEYNAMES[key], ad)] += 1
                        else:
                            per_section[secname][("rebase",)] += 1
                    if nxt == 0:
                        break
                    loc += nxt * stride

    for secname in sorted(per_section):
        total = sum(per_section[secname].values())
        print("   %-28s %5d  %s" % (secname, total,
              ", ".join("%s:%d" % ("/".join(map(str, k)), c)
                        for k, c in sorted(per_section[secname].items(), key=lambda kv: -kv[1]))))


if __name__ == '__main__':
    for p in sys.argv[1:]:
        analyse(p)
        print()
