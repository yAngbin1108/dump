#!/usr/bin/env python3
"""
authify_objc.py — give an arm64e binary the pointer-authenticated ObjC metadata
that iOS 14+ expects.

Why this exists
---------------
On arm64e the Objective-C runtime authenticates the pointers inside class_t
before it uses them: isa, superclass and the class_ro_t* in `data`. Apple's
compiler (clang 12+, Xcode 12+) emits those pointers with
ARM64_RELOC_AUTHENTICATED_* relocations, so Apple's linker records them in the
chained-fixup table as *auth* fixups. Linux clang — 11 from theos, 18 from the
distro, the clang 10 of sbingner's arm64e toolchain — never emits them, so the
same table comes out with plain rebases/binds.

Result on device: launchd accepts the binary once its cpusubtype says ptrauth
ABI v2, dyld loads it, and then libobjc faults authenticating an unsigned isa —
black screen, immediate exit, no crash report worth reading.

What the fix is
---------------
Rewrite the affected chained-fixup words in place, from plain to auth form. The
parameters are not guessed: they were decoded out of a shipping arm64e binary
built by Xcode (Cyanide), where all 41 classes follow one rule —

    class_t + 0x00  isa         auth rebase, key DA, addrDiv 1, div 0x6ae1
    class_t + 0x08  superclass  auth bind,   key DA, addrDiv 1, div 0xb5ab
    class_t + 0x20  data        auth rebase, key DA, addrDiv 1, div 0x61f8

0x6ae1 and 0x61f8 are __builtin_ptrauth_string_discriminator("isa") and
("class_data_bits"); 0xb5ab is the superclass discriminator. `cache` stays a
plain bind (it is empty at link time) and `vtable` carries no fixup at all.
Metaclasses are reached the same way and follow the same slot rule; whether a
slot becomes an auth *bind* or auth *rebase* is taken from what the linker
already put there.

Usage: authify_objc.py <arm64e-macho> [--verbose]
Runs before signing (the signature must cover the rewritten table).
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

# class_t slots that libobjc authenticates, with the discriminator Apple's
# toolchain uses for each. Values decoded from a shipping Xcode-built arm64e
# binary; `isa` and `class_data_bits` were confirmed as string discriminators.
SLOT_ISA = (0x00, 0x6AE1)
SLOT_SUPERCLASS = (0x08, 0xB5AB)
SLOT_DATA = (0x20, 0x61F8)
SLOTS = (SLOT_ISA, SLOT_SUPERCLASS, SLOT_DATA)

PTRAUTH_KEY_DA = 2

# Symbols whose address is an object's isa. libobjc authenticates those with
# the "isa" discriminator before use, so a plain bind makes the first retain /
# msgSend fault. Measured against a shipping Xcode-built arm64e binary:
#   ___CFConstantStringClassReference  2641 auth binds, div 0x6ae1
#   __NSConcreteGlobalBlock              87 auth binds, div 0x6ae1
#   _OBJC_CLASS_$_NSConstant*            220 auth binds, div 0x6ae1
ISA_SYMBOL_EXACT = (
    '___CFConstantStringClassReference',
    '__NSConcreteGlobalBlock',
    '__NSConcreteStackBlock',
    '__NSConcreteMallocBlock',
)
ISA_SYMBOL_PREFIX = (
    '_OBJC_CLASS_$_NSConstant',
)


def is_isa_symbol(name):
    if name in ISA_SYMBOL_EXACT:
        return True
    return any(name.startswith(p) for p in ISA_SYMBOL_PREFIX)


def die(msg):
    sys.exit("authify_objc: " + msg)


class MachO:
    def __init__(self, path):
        self.path = path
        self.d = bytearray(open(path, 'rb').read())
        magic, cputype, cpusubtype = struct.unpack_from('<III', self.d, 0)
        if magic != MH_MAGIC_64:
            die("%s is not a 64-bit Mach-O" % path)
        if cputype != CPU_TYPE_ARM64 or (cpusubtype & 0xFFFFFF) != CPU_SUBTYPE_ARM64E:
            die("%s is not arm64e (cputype=0x%x cpusubtype=0x%08x)"
                % (path, cputype, cpusubtype))
        self.segs = []          # (name, vmaddr, vmsize, fileoff, filesize)
        self.secs = {}          # "seg,sec" -> (addr, size, fileoff)
        self.fixups = None      # (dataoff, datasize)
        self._parse_load_commands()

    def _parse_load_commands(self):
        ncmds = struct.unpack_from('<I', self.d, 16)[0]
        off = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', self.d, off)
            if cmd == LC_SEGMENT_64:
                name = self.d[off + 8:off + 24].rstrip(b'\0').decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', self.d, off + 24)
                self.segs.append((name, vmaddr, vmsize, fileoff, filesize))
                nsects = struct.unpack_from('<I', self.d, off + 64)[0]
                so = off + 72
                for _ in range(nsects):
                    sname = self.d[so:so + 16].rstrip(b'\0').decode()
                    saddr, ssize = struct.unpack_from('<QQ', self.d, so + 32)
                    self.secs[name + ',' + sname] = (saddr, ssize, fileoff + (saddr - vmaddr))
                    so += 80
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                self.fixups = struct.unpack_from('<II', self.d, off + 8)
            off += size
        if not self.fixups:
            die("%s has no LC_DYLD_CHAINED_FIXUPS (link it with -fixup_chains)" % self.path)

    def section(self, key):
        if key not in self.secs:
            die("%s has no section %s" % (self.path, key))
        return self.secs[key]

    def vm2off(self, addr):
        for _, vmaddr, vmsize, fileoff, _ in self.segs:
            if vmaddr <= addr < vmaddr + vmsize:
                return fileoff + (addr - vmaddr)
        return None

    def seg_index_of(self, addr):
        for i, (_, vmaddr, vmsize, _, _) in enumerate(self.segs):
            if vmaddr <= addr < vmaddr + vmsize:
                return i
        return None

    def image_base(self):
        for name, vmaddr, _, _, _ in self.segs:
            if name == '__TEXT':
                return vmaddr
        die("no __TEXT segment")

    def imports(self):
        """[(library_ordinal, name)] from the fixups blob."""
        base = self.fixups[0]
        (version, starts, imports, symbols, icount,
         ifmt, symfmt) = struct.unpack_from('<IIIIHBB', self.d, base)
        out = []
        for i in range(icount):
            v, = struct.unpack_from('<I', self.d, base + imports + 4 * i)
            noff = v >> 9
            end = self.d.index(b'\0', base + symbols + noff)
            out.append(self.d[base + symbols + noff:end].decode())
        return out

    def walk_chains(self):
        """Yield (file_offset, raw_word) for every fixup in the table."""
        base = self.fixups[0]
        (version, starts, imports, symbols, icount,
         ifmt, symfmt) = struct.unpack_from('<IIIIHBB', self.d, base)
        if version != 0:
            die("unknown chained-fixups version %d" % version)
        segcount = struct.unpack_from('<I', self.d, base + starts)[0]
        for si in range(segcount):
            (so,) = struct.unpack_from('<I', self.d, base + starts + 4 + 4 * si)
            if not so:
                continue
            p = base + starts + so
            (size, page_size, pfmt, seg_off,
             max_valid, page_count) = struct.unpack_from('<IHHQIH', self.d, p)
            if pfmt not in (1, 12):
                # 1 = ARM64E (what ld64 writes), 12 = ARM64E_USERLAND24 (what
                # Xcode's newer linker writes). Both walk with an 8-byte stride;
                # only the bind ordinal width differs.
                die("unexpected pointer_format %d" % pfmt)
            segstart = self.segs[si][3]
            segvm = self.segs[si][1]
            page_start = struct.unpack_from('<%dH' % page_count, self.d, p + 22)
            for pi in range(page_count):
                if page_start[pi] == 0xFFFF:
                    continue
                loc = segstart + pi * page_size + page_start[pi]
                for _ in range(20000):
                    word = struct.unpack_from('<Q', self.d, loc)[0]
                    # Address and file offset together: mapping them back later
                    # through the segment table broke for __DATA_CONST, whose
                    # vm size does not cover its file size.
                    yield segvm + (loc - segstart), loc, word, pfmt
                    nxt = (word >> NEXT_SHIFT) & NEXT_MASK
                    if nxt == 0:
                        break
                    loc += nxt * 8


def authify(path, verbose=False):
    m = MachO(path)
    base_vm = m.image_base()

    # Index every fixup word by the virtual address it sits at.
    words = {}
    for vm, off, word, pfmt in m.walk_chains():
        words[vm] = [off, word, pfmt]

    def rebase_target(word, pfmt):
        """vmaddr a plain rebase points at.

        The two arm64e formats store different things in `target`:
          format 1  (DYLD_CHAINED_PTR_ARM64E)          -> unslid vmaddr
          format 12 (DYLD_CHAINED_PTR_ARM64E_USERLAND24) -> offset from __TEXT
        """
        target = word & ((1 << 43) - 1)
        high8 = (word >> 43) & 0xFF
        if pfmt == 1:
            return target + (high8 << 56)
        return base_vm + target + (high8 << 56)

    cls_addr, cls_size, cls_off = m.section('__DATA_CONST,__objc_classlist')
    classes = []
    for i in range(cls_size // 8):
        entry = cls_addr + 8 * i
        if entry not in words:
            continue
        word = words[entry][1]
        if (word >> BIND_BIT) & 1:
            continue        # a bound class: nothing local to authenticate
        classes.append(rebase_target(word, words[entry][2]))

    # Every class also has a metaclass, reached through class->isa.
    structs = list(classes)
    for c in classes:
        isa = words.get(c)
        if isa and not ((isa[1] >> BIND_BIT) & 1):
            structs.append(rebase_target(isa[1], isa[2]))

    # Every remaining plain bind that resolves to an isa symbol gets the "isa"
    # signature too: block literals, CFString literals, tagged-pointer classes.
    imports = m.imports()
    isa_extra = 0
    for vm, (foff, word, pfmt) in list(words.items()):
        if not ((word >> BIND_BIT) & 1) or ((word >> AUTH_BIT) & 1):
            continue
        ordinal = (word & 0xFFFFFF) if pfmt == 12 else (word & 0xFFFF)
        if ordinal >= len(imports):
            continue
        if not is_isa_symbol(imports[ordinal]):
            continue
        # Skip indirect-symbol slots: GOT entries stay plain binds and the call
        # site authenticates them itself (Cyanide ships __NSConcreteStackBlock
        # exactly that way). Only *data* slots holding an isa are signed here.
        sec_name = None
        for key, (s0, sz, _fo) in m.secs.items():
            if s0 <= vm < s0 + sz:
                sec_name = key.split(',')[-1]
                break
        if sec_name in ('__got', '__auth_got', '__auth_ptr'):
            continue
        nxt = (word >> NEXT_SHIFT) & NEXT_MASK
        if pfmt == 12:
            new = ((word & 0xFFFFFF) | ((word >> 24 & 0xFF) << 24)
                   | (SLOT_ISA[1] << 32) | (1 << 48)
                   | (PTRAUTH_KEY_DA << 49) | (nxt << NEXT_SHIFT)
                   | (1 << BIND_BIT) | (1 << AUTH_BIT))
        else:
            new = ((word & 0xFFFF) | ((word >> 16 & 0xFFFF) << 16)
                   | (SLOT_ISA[1] << 32) | (1 << 48)
                   | (PTRAUTH_KEY_DA << 49) | (nxt << NEXT_SHIFT)
                   | (1 << BIND_BIT) | (1 << AUTH_BIT))
        struct.pack_into('<Q', m.d, foff, new)
        words[vm][1] = new
        isa_extra += 1

    stats = {'isa': 0, 'superclass': 0, 'data': 0, 'skipped': 0}
    changed = 0
    for s in structs:
        for off, div in SLOTS:
            slot = s + off
            if slot not in words:
                continue
            foff, word, pfmt = words[slot]
            if (word >> AUTH_BIT) & 1:
                continue        # already authenticated
            is_bind = (word >> BIND_BIT) & 1
            nxt = (word >> NEXT_SHIFT) & NEXT_MASK
            if is_bind:
                if pfmt == 12:
                    ordinal = word & 0xFFFFFF
                    zero = (word >> 24) & 0xFF
                    new = (ordinal | (zero << 24)
                           | (div << 32) | (1 << 48)
                           | (PTRAUTH_KEY_DA << 49)
                           | (nxt << NEXT_SHIFT)
                           | (1 << BIND_BIT) | (1 << AUTH_BIT))
                    struct.pack_into('<Q', m.d, foff, new)
                    words[slot][1] = new
                    changed += 1
                    stats['isa' if off == 0 else 'superclass' if off == 8 else 'data'] += 1
                    continue
                ordinal = word & 0xFFFF
                zero = (word >> 16) & 0xFFFF
                new = (ordinal
                       | (zero << 16)
                       | (div << 32)
                       | (1 << 48)                  # addrDiv
                       | (PTRAUTH_KEY_DA << 49)
                       | (nxt << NEXT_SHIFT)
                       | (1 << BIND_BIT)
                       | (1 << AUTH_BIT))
                kind = 'auth_bind'
            else:
                # an auth rebase stores a 32-bit offset from the image base
                target = rebase_target(word, pfmt) - base_vm
                if target < 0 or target >= (1 << 32):
                    stats['skipped'] += 1
                    if verbose:
                        print("    skip %#x: rebase target %#x does not fit "
                              "32 bits" % (slot, target))
                    continue
                new = (target
                       | (div << 32)
                       | (1 << 48)
                       | (PTRAUTH_KEY_DA << 49)
                       | (nxt << NEXT_SHIFT)
                       | (1 << AUTH_BIT))
                kind = 'auth_rebase'
            struct.pack_into('<Q', m.d, foff, new)
            words[slot][1] = new
            changed += 1
            stats['isa' if off == 0 else 'superclass' if off == 8 else 'data'] += 1
            if verbose:
                print("    %#x %-11s -> %s div=%#06x" % (slot, kind, kind, div))

    changed += isa_extra
    if not changed:
        print("    no ObjC metadata needed authenticating")
        return 0

    open(path, 'wb').write(m.d)
    print("    %d classes, %d structs: isa=%d superclass=%d data=%d, "
          "isa-symbol binds=%d%s"
          % (len(classes), len(structs), stats['isa'], stats['superclass'],
             stats['data'], isa_extra,
             (", skipped=%d" % stats['skipped']) if stats['skipped'] else ""))
    return changed


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if not args:
        sys.exit(__doc__)
    total = 0
    for p in args:
        print("==> authify %s" % p)
        total += authify(p, verbose=('-v' in sys.argv or '--verbose' in sys.argv))
    sys.exit(0 if total else 1)
