#!/usr/bin/env python3
"""
stamp_ptrauth_abi.py — mark an arm64e object file as built for ptrauth ABI v2.

Why: ld64-609 decides an arm64e object's ABI from the object's own cpusubtype,
and refuses ABI v1 objects ("object file … was built with an incompatible
arm64e ABI compiler") because iOS 14+ moved to ptrauth ABI v2
(CPU_SUBTYPE_PTRAUTH_ABI | CPU_SUBTYPE_ARM64E = 0x80000002). clang-11 — Linux
theos's only compiler — predates that change and stamps a plain 0x2 on every
arm64e object, so the link silently runs in ABI v1 mode and the resulting app
does not survive launch.

Measured locally: patching the object's cpusubtype to 0x80000002 before linking
removes ld64's warning and makes the linked output carry 0x80000002 by itself,
with the ObjC image info and chained fixups unchanged.

Usage: stamp_ptrauth_abi.py <object-or-macho> [...]
"""
import struct
import sys

ARM64 = 0x0100000C
ARM64E = 2
PTRAUTH_ABI_V2 = 0x80000002

rc = 0
for path in sys.argv[1:]:
    d = bytearray(open(path, 'rb').read())
    magic, cputype, cpusubtype = struct.unpack_from('<III', d, 0)
    if magic != 0xFEEDFACF or cputype != ARM64 or (cpusubtype & 0xFFFFFF) != ARM64E:
        print("    skip %s (not an arm64e Mach-O)" % path)
        rc = 1
        continue
    if cpusubtype == PTRAUTH_ABI_V2:
        continue
    struct.pack_into('<I', d, 8, PTRAUTH_ABI_V2)
    open(path, 'wb').write(d)
    print("    %s: cpusubtype 0x%08x -> 0x80000002" % (path.split('/')[-1], cpusubtype))
sys.exit(0 if rc == 0 else 1)
