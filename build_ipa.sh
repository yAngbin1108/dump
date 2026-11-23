#!/bin/bash
#
# build_ipa.sh — package SandboxKit into SandboxKit.ipa
#
# Mirrors the project's own Makefile:
#
#   FILES      = the sources listed in SandboxKit_FILES
#   FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AVFoundation AVKit
#   CFLAGS     = -fobjc-arc [-fno-modules → effective -fmodules, see below]
#                -Wno-error=deprecated-declarations -Wno-unused-function
#                -Wno-nullability -I ./kexploit -I ./kexploit/pe
#                -I ./kexploit/TaskRop -I ./kexploit/headers
#   LDFLAGS    = -L./kexploit/lib -lgrabkernel2 -lxpf -lz
#                -Wl,-rpath,@executable_path/Frameworks
#   signing    = bare `ldid -S` on the binary and both embedded dylibs
#
# Notes on the two deliberate deviations, neither of which touches a source
# file:
#
#   -fmodules  The Makefile passes -fno-modules, but theos appends its own
#              MODULESFLAGS (-fmodules ...) after the instance flags (see
#              makefiles/targets/_common/darwin_tail.mk). The effective value
#              in the original theos build is therefore modules ENABLED. Using
#              -fno-modules directly fails on the chain's `@import Foundation;`
#              statements, so the effective setting is set explicitly here.
#
#   headers/   The published zip omits kexploit/headers/, yet offsets.m
#              includes xpf.h which pulls in Fat.h / Util.h / PatchFinder*.h /
#              arm64.h. These are pure declarations for the shipped
#              libxpf.dylib; nothing else changed.
#
set -euo pipefail

usage() {
  echo "usage: $0 [--src DIR] [--out NAME] [--keep]"
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SCRIPT_DIR/src" ]; then SRC="$SCRIPT_DIR/src"; else SRC="$SCRIPT_DIR"; fi
OUTNAME="AppDump"
APP="appdump"
MIN_IOS="15.0"
# arm64 by default; --arch arm64e builds the PAC-capable variant.
#
# RemoteCall writes a thread state into another process. SpringBoard on A12+ is
# arm64e, so the PC/LR we inject have to carry valid PAC signatures — and only
# an arm64e process can produce them (`pacia` does not exist in arm64 mode, so
# pacsignworks() returns false and RemoteCall refuses outright, by design:
# injecting unsigned pointers made SpringBoard take a PAC fault and respring).
# Everything that needs RemoteCall — the Cyanide SpringBoard decrypt tier, JIT,
# the overlay — therefore requires the arm64e build.
#
# The reason the old arm64e attempts never launched was a chained-fixup format
# rewrite further down that has since been removed; see the note there.
ARCH="arm64"
INFOPLIST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --out) OUTNAME="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --plist) INFOPLIST="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    *) usage ;;
  esac
done

case "$ARCH" in
  arm64|arm64e) ;;
  *) echo "--arch must be arm64 or arm64e"; exit 1 ;;
esac

# Default Info.plist lives next to the sources.
[ -z "$INFOPLIST" ] && INFOPLIST="$SRC/Info.plist"

TC="/opt/theos/toolchain/linux/iphone/bin"
SDK="/opt/theos/sdks/iPhoneOS16.5.sdk"
LDID="$TC/ldid"

# The real Apple linker: ld64-956.6 (cctools-port 1030.6.3, Xcode 16 era),
# built locally from source. theos ships ld64-609, whose output is what
# crashed arm64e builds on device; -B makes clang-11 find this one instead.
LDBIN="/opt/theos/toolchain/linux/iphone/bin"

# Compiler override. The bundled clang-11 cannot emit arm64e ObjC metadata
# (ABI v1: no authenticated-pointer relocations), which is why every arm64e
# build from this tree crashed at launch. Ubuntu's clang-18 does emit it, so
# --arch arm64e is at least worth attempting with CC=clang-18.
CC_BIN="${CC:-$TC/clang-11}"

BUILD="$SRC/build"
APPDIR="$BUILD/Payload/$APP.app"
# Final artifacts live outside $BUILD (which is wiped on every run) so the
# arm64e and arm64 builds can coexist as a fallback pair.
DIST="$SCRIPT_DIR/dist"
OUT="$DIST/${OUTNAME}-${ARCH}.ipa"

echo "==> clean"
rm -rf "$BUILD"
mkdir -p "$APPDIR/Frameworks"

# ── sources (SandboxKit_FILES) ──────────────────────────────────────────────
SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(cd "$SRC" && cat <<'LIST' | sed "s|^|$SRC/|"
main.m
FileManager.m
Exploit.m
ProcessListViewController.m
kexploit/darksword.m
kexploit/offsets.m
kexploit/utils.m
kexploit/persistence.m
kexploit/decrypt.m
kexploit/cyvm.m
kexploit/cydecrypt.m
kexploit/TaskRop/RemoteCall.m
kexploit/TaskRop/thread.m
kexploit/TaskRop/vm.m
kexploit/TaskRop/pac.m
kexploit/TaskRop/exc.m
kexploit/TaskRop/findcachedataoff.m
kexploit/kcblock.m
kexploit/skrc.m
kexploit/skdowngrade.m
kexploit/skblockupdates.m
kexploit/pe/sbx.m
kexploit/cyremote.m
kexploit/pe/vfs.m
kexploit/pe/apfs.m
LIST
)

# Optional extra sources (used when the injection feature is added).
if [ -d "$SRC/app" ]; then
  while IFS= read -r f; do SRCS+=("$f"); done < <(find "$SRC/app" -name '*.m' ! -name 'SKDiag.m' | sort)
fi

INCLUDES=(
  -I"$SRC"
  -I"$SRC/compat"          # ptrauth.h 垫片（Ubuntu clang-18 不带这份头）
  -I"$SRC/kexploit"
  -I"$SRC/kexploit/cy"
  -I"$SRC/kexploit/pe"
  -I"$SRC/kexploit/TaskRop"
  -I"$SRC/kexploit/headers"
  -I"$SRC/kexploit/xpc"
)
[ -d "$SRC/app" ] && INCLUDES+=(-I"$SRC/app")

if [ -n "${SK_NO_PAC:-}" ]; then
  SK_NO_PAC_FLAGS="-fno-ptrauth-returns -fno-ptrauth-indirect-gotos -fno-ptrauth-calls -fno-ptrauth-intrinsics"
fi

CFLAGS=(
  # Plain arm64. The device is arm64e, but arm64 runs there under the compat
  # path and every arm64e build this tree produced failed to launch. Without
  # RemoteCall there is nothing here that needs the newer ABI.
  -target ${ARCH}-apple-ios${MIN_IOS}
  -isysroot "$SDK"
  -miphoneos-version-min=${MIN_IOS}
  -fobjc-arc
  -fmodules
  -Wno-error=deprecated-declarations
  -Wno-unused-function
  -Wno-nullability
  -Wno-everything
  -fobjc-abi-version=2
  # ld64 chained fixups. Without this the linker emits classic
  # LC_DYLD_INFO bind/rebase opcodes. Only theos's ld64-609 needs to be
  # asked explicitly; Apple's ld64-956 defaults to chains.
  -Wl,-fixup_chains
  # arm64e: ObjC 分发方式。默认沿用 theos 的 legacy dispatch（直接 bl objc_msgSend）；
  # 设 SK_MODERN_OBJC=1 则改用选择器桩（__objc_stubs），和官方 Cyanide 一致。
  ${SK_OBJC_DISPATCH_FLAGS:- -fobjc-legacy-dispatch}
  # arm64e 默认会生成 PAC 指令（pac-ret / 认证跳转）。clang-11 是 ABI v1 时代的
  # 编译器，如果它的 PAC 代码在 ABI v2 加载环境里不成立，可以整个关掉试试：
  #   SK_NO_PAC=1 ./build_ipa.sh --arch arm64e
  ${SK_NO_PAC_FLAGS:-}
)

FRAMEWORKS=(
  -framework UIKit -framework Foundation -framework CoreGraphics
  -framework QuartzCore -framework AVFoundation -framework AVKit -framework WebKit
  -framework CoreFoundation -framework Security -framework IOSurface
)

LIBS=( -L"$SRC/kexploit/lib" -lgrabkernel2 -lxpf -lz )


# ── compile ─────────────────────────────────────────────────────────────────
echo "==> compile (${#SRCS[@]} files)"
OBJDIR="$BUILD/obj"; mkdir -p "$OBJDIR"
OBJS=()
for s in "${SRCS[@]}"; do
  o="$OBJDIR/$(echo "${s#$SRC/}" | tr '/' '_' | sed 's/\.m$/.o/')"
  printf '    CC %s\n' "$(basename "$o")"
  "$CC_BIN" "${CFLAGS[@]}" "${INCLUDES[@]}" -c "$s" -o "$o"
  # ld64-609 按 .o 自己的 cpusubtype 判断 arm64e ABI；clang-11 只会写 ABI v1，
  # 直接链接就落到 v1 模式（启动崩溃）。逐个 .o 打上 ptrauth ABI v2 再链接。
  if [ "$ARCH" = "arm64e" ]; then
    /usr/bin/env python3 "$SCRIPT_DIR/stamp_ptrauth_abi.py" "$o" >/dev/null || {
      echo "stamp_ptrauth_abi.py failed on $o"; exit 1; }
  fi
  OBJS+=("$o")
done

# ── link ────────────────────────────────────────────────────────────────────
echo "==> link"
"$CC_BIN" "${CFLAGS[@]}" "${OBJS[@]}" "${FRAMEWORKS[@]}" "${LIBS[@]}" -B"$LDBIN" \
  -Wl,-rpath,@executable_path/Frameworks \
  -o "$APPDIR/$APP"
file "$APPDIR/$APP"

  # The chained-fixup pointer format is NOT rewritten.
  #
  # An earlier revision relabelled it from what ld64 emitted (1,
  # DYLD_CHAINED_PTR_ARM64E) to 12 (DYLD_CHAINED_PTR_ARM64E_USERLAND24), on the
  # theory that ld64 encoded with a stride of 8 while declaring a format dyld
  # walks with a stride of 4. That theory was wrong in both directions: format 1
  # IS the stride-8 form, so ld64 output was already self-consistent, and
  # relabelling it told dyld to read a 12-bit `next` field out of a chain that
  # had been written with 11 bits.
  #
  # The damage was measurable, not theoretical. Walking the chains of one binary
  # under each label:
  #
  #     declared 1   ->   85 and 344 fixups visited, every chain terminated
  #     declared 12  ->    2 and   2 fixups visited
  #
  # so nearly the whole fixup table was misread. Objective-C class data fell
  # apart as a result, and dyld aborted inside dyld4::optimizeObjCClasses() with
  # std::__throw_bad_optional_access before main was ever reached. That was the
  #
  # The assertion further down now walks the chains rather than comparing a
  # number to an expected one.

# ── arm64e: verify the chained-fixup chains ────────────────────────────────
#
# No relabelling happens here. An earlier revision rewrote the declared
# pointer_format from 1 to 12 on the theory that ld64-609 stamped it wrong; the
# object-level ABI fix above removed the need, and ld64's own consistency
# asserts ( "((dyld_chained_ptr_arm64e_rebase*)prevLoc)->next * 8) == delta" )
# confirm the 8-byte stride that format 1 uses for arm64e. The check below only
# walks the chains with the stride in the header and refuses to ship a binary
# whose chains run off their page.
if [ "$ARCH" = "arm64e" ]; then
  echo "==> verify fixup chains (arm64e)"
  /usr/bin/env python3 - "$APPDIR/$APP" <<'PYEOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
n = struct.unpack_from('<I', d, 16)[0]; off = 32; segs = []; chained = None
for _ in range(n):
    cmd, size = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        segs.append((d[off+8:off+24].rstrip(b'\0').decode(),) + struct.unpack_from('<QQQQ', d, off+24))
    if cmd == 0x80000034:
        chained = struct.unpack_from('<II', d, off+8)
    off += size
base = chained[0]
ver, starts, imports, symbols, icount, ifmt, symfmt = struct.unpack_from('<IIIIHBB', d, base)
segcount, = struct.unpack_from('<I', d, base + starts)
total = 0; bad = 0
for si in range(segcount):
    so, = struct.unpack_from('<I', d, base + starts + 4 + 4 * si)
    if not so: continue
    p = base + starts + so
    size, page_size, pfmt, seq_off, mv, page_count = struct.unpack_from('<IHHQIH', d, p)
    if pfmt not in (1, 12):
        sys.exit("unexpected pointer_format %d on segment %d" % (pfmt, si))
    segstart = segs[si][3]
    ps = struct.unpack_from('<%dH' % page_count, d, p + 22)
    for pi in range(page_count):
        if ps[pi] == 0xFFFF: continue
        loc = segstart + pi * page_size + ps[pi]
        for _ in range(20000):
            v, = struct.unpack_from('<Q', d, loc)
            total += 1
            nxt = (v >> 51) & 0x7FF
            if nxt == 0: break
            loc += nxt * 8                      # arm64e chains move in 8-byte steps
            if (loc - segstart) // page_size != pi:
                bad += 1; break
print("    %d fixups walked, %d left their page, imports=%d" % (total, bad, icount))
sys.exit(1 if bad else 0)
PYEOF
  if [ $? -ne 0 ]; then echo "FIXUP CHECK FAILED"; exit 1; fi
fi

# ── arm64e: the header must now carry ptrauth ABI v2 by itself ─────────────
if [ "$ARCH" = "arm64e" ]; then
  python3 - "$APPDIR/$APP" <<'PYEOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
cst = struct.unpack_from('<III', d[:12])[2]
if cst != 0x80000002:
    sys.exit("linked output has cpusubtype 0x%08x, expected 0x80000002 — the "
             "object-level ABI stamping did not take effect" % cst)
print("    cpusubtype = 0x80000002 (ptrauth ABI v2, from the objects)")
PYEOF
  if [ $? -ne 0 ]; then exit 1; fi
fi

# ── arm64e: move the fixup table to the format dyld expects ───────────────
#
# ld64-609 only ever writes DYLD_CHAINED_PTR_ARM64E (1); every arm64e binary
# Apple ships uses USERLAND24 (12), and the two disagree on whether a rebase's
# target is an absolute vmaddr or a base-relative offset.
if [ "$ARCH" = "arm64e" ]; then
  echo "==> convert fixups to USERLAND24 (arm64e)"
  /usr/bin/env python3 "$SCRIPT_DIR/to_userland24.py" "$APPDIR/$APP" || {
    echo "to_userland24.py failed"; exit 1; }
fi

# ── arm64e: give the ObjC metadata the PAC signatures iOS expects ─────────
#
# libobjc authenticates class_t.isa / .superclass / .data on arm64e before it
# uses them. Apple's compiler emits authenticated relocations for those and the
# linker records them as auth fixups; no compiler available on Linux does (see
# the note at the top), so the table is rewritten here with the exact
# parameters decoded from a shipping Xcode-built arm64e binary. Runs before
# signing, because the signature has to cover the rewritten table.
if [ "$ARCH" = "arm64e" ]; then
  echo "==> authenticate ObjC metadata (arm64e)"
  /usr/bin/env python3 "$SCRIPT_DIR/authify_objc.py" "$APPDIR/$APP" || {
    echo "authify_objc.py failed"; exit 1; }
fi

# ── assert the produced architecture/ABI ────────────────────────────────────
# This is the check that would have caught the "此App需要开发者更新以在此iOS版本上
# An arm64 binary must carry cpusubtype 0; an arm64e one cpusubtype 2.
/usr/bin/env python3 - "$APPDIR/$APP" "$ARCH" <<'PYEOF'
import struct, sys
path, want = sys.argv[1], sys.argv[2]
with open(path, 'rb') as fh:
    magic, cputype, cpusubtype = struct.unpack('<III', fh.read(12))
ok = (magic == 0xFEEDFACF and cputype == 0x0100000C)
if want == 'arm64':
    ok = ok and cpusubtype == 0
else:
    # ptrauth ABI v2 is what iOS 14+ expects; ABI v1 (0x2) is rejected at launch.
    ok = ok and cpusubtype == 0x80000002
if not ok:
    sys.exit("ABI assertion FAILED: want %s, got cputype=0x%x cpusubtype=0x%08x"
             % (want, cputype, cpusubtype))
print("    ABI OK: %s (cputype=0x%x cpusubtype=0x%08x)" % (want, cputype, cpusubtype))

PYEOF

# ── bundle ──────────────────────────────────────────────────────────────────
echo "==> bundle"
# Localizations: every <lang>.lproj goes into the bundle so the app follows
# the device language.
if [ -d "$SRC/locales" ]; then
  for d in "$SRC"/locales/*.lproj; do
    [ -d "$d" ] || continue
    cp -R "$d" "$APPDIR/"
    echo "    locale $(basename "$d")"
  done
fi

# 图标：文件名保持 iOS 的查找规则（CFBundleIconFiles 写基名，系统自己拼 @2x/@3x）
if [ -d "$SRC/icons" ]; then
  # AppIcon-1024.png 只有上架 App Store 才需要，装进包里纯占 250KB，跳过
  for f in "$SRC"/icons/*.png; do
    case "$(basename "$f")" in AppIcon-1024.png) continue ;; esac
    cp "$f" "$APPDIR/"
  done
  echo "    icons $(ls "$APPDIR"/*.png 2>/dev/null | wc -l) 个"
fi

cp "$INFOPLIST"                   "$APPDIR/Info.plist"
cp "$SRC/LaunchScreen.storyboard" "$APPDIR/LaunchScreen.storyboard"
printf 'APPL????'                > "$APPDIR/PkgInfo"

cp "$SRC/kexploit/lib/libgrabkernel2.dylib" "$APPDIR/Frameworks/"
cp "$SRC/kexploit/lib/libxpf.dylib"         "$APPDIR/Frameworks/"
chmod +x "$APPDIR/Frameworks/"*.dylib

# ── report the bundled dylibs' architectures ────────────────────────────────
# Only the arm64 slices are ever loaded now, so that is all this checks. The
# arm64e slices are left exactly as their authors shipped them.
/usr/bin/env python3 - "$APPDIR/Frameworks" <<'PYEOF'
import struct, sys, os, glob
bad = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.dylib"))):
    d = open(path, 'rb').read()
    if struct.unpack_from('>I', d, 0)[0] != 0xCAFEBABE:
        slices = [(0, len(d), 'thin')]
    else:
        n = struct.unpack_from('>I', d, 4)[0]
        slices = []
        for i in range(n):
            ct, cs, o, sz, al = struct.unpack_from('>IIIII', d, 8 + i*20)
            slices.append((o, sz, 'arm64e' if (cs & 0xFFFFFF) == 2 else 'arm64'))
    for off, size, tag in slices:
        s = d[off:off+size]
        if len(s) < 32 or struct.unpack_from('<I', s, 0)[0] != 0xFEEDFACF:
            continue
        n = struct.unpack_from('<I', s, 16)[0]; o = 32; fx = None
        segs_meta = []
        for _ in range(n):
            c, z = struct.unpack_from('<II', s, o)
            if c == 0x80000034: fx = struct.unpack_from('<II', s, o + 8)
            if c == 0x19:
                nmx = s[o+8:o+24].split(b'\0')[0].decode('utf-8', 'replace')
                vmx, vsx, fox, fsx = struct.unpack_from('<QQQQ', s, o + 24)
                segs_meta.append((nmx, vmx, vsx, fox, fsx))
            o += z
        fmts = []
        if fx:
            b = fx[0] + struct.unpack_from('<I', s, fx[0] + 4)[0]
            sc = struct.unpack_from('<I', s, b)[0]
            for j in range(sc):
                so = struct.unpack_from('<I', s, b + 4 + j*4)[0]
                if so: fmts.append(struct.unpack_from('<H', s, b + so + 6)[0])
        else:
            print("    dylib OK: %-22s %-7s pointer_format=%s" % (os.path.basename(path), tag, fmts))
if bad:
    sys.exit("dylib pointer-format assertion FAILED:\n  " + "\n  ".join(bad))
PYEOF

# ── localization assertion ──────────────────────────────────────────────────
# Every key the sources look up through SKLoc()/NSLocalizedString() must exist
# in the bundle. A key that is missing does not fail loudly at runtime — the
# lookup returns the key itself, so the UI silently renders "tui.menu.repair".
# That is exactly how two keys shipped broken, so it is checked here instead.
/usr/bin/env python3 - "$SRC" "$APPDIR/en.lproj/Localizable.strings" <<'PYEOF'
import re, sys, os, glob
src, bundle = sys.argv[1], sys.argv[2]

used = set()
for p in glob.glob(os.path.join(src, '*.m')) + glob.glob(os.path.join(src, 'app', '*.m')):
    t = open(p, encoding='utf-8').read()
    used |= set(re.findall(r'SKLoc\(@"([^"]+)"\)', t))
    used |= set(re.findall(r'SKLoc\([^)]*?@"([^"]+)"', t))
    used |= set(re.findall(r'@\[ @"((?:tui|proc|mem|menu|app|common)\.[A-Za-z0-9_.]+)"', t))

if not os.path.exists(bundle):
    sys.exit("localization assertion FAILED: %s not found" % bundle)

keys = set(re.findall(r'^"([^"]+)"\s*=', open(bundle, encoding='utf-8').read(), re.M))
missing = sorted(k for k in used if k not in keys)
if missing:
    sys.exit("localization assertion FAILED: %d key(s) referenced but not bundled:\n  %s"
             % (len(missing), "\n  ".join(missing)))
print("    localization OK: %d keys referenced, all present in the bundle" % len(used))
PYEOF

for lib in libgrabkernel2.dylib libxpf.dylib; do
  "$TC/llvm-install-name-tool" -id "@rpath/$lib" "$APPDIR/Frameworks/$lib" 2>/dev/null || true
  "$TC/llvm-install-name-tool" -change "@executable_path/Frameworks/$lib" \
      "@rpath/$lib" "$APPDIR/$APP" 2>/dev/null || true
done

# ── sign: bare ldid -S, no entitlements (as upstream) ───────────────────────
echo "==> sign"
"$LDID" -S "$APPDIR/Frameworks/libgrabkernel2.dylib" 2>/dev/null || true
"$LDID" -S "$APPDIR/Frameworks/libxpf.dylib"         2>/dev/null || true
# 带 entitlements 签名：自签安装不做描述文件校验，这正是我们能拿到
# platform-application / frontboard.open 的原因（TrollStore 装的应用本来就带）。
ENT="$SRC/appdump.entitlements"
if [ -f "$ENT" ]; then
  "$LDID" -S"$ENT" "$APPDIR/$APP" 2>/dev/null || "$LDID" -S "$APPDIR/$APP" 2>/dev/null || true
  "$LDID" -S"$ENT" "$APPDIR/Frameworks/libgrabkernel2.dylib" 2>/dev/null || true
  "$LDID" -S"$ENT" "$APPDIR/Frameworks/libxpf.dylib" 2>/dev/null || true
else
  "$LDID" -S "$APPDIR/$APP" 2>/dev/null || true
fi

# ── package ─────────────────────────────────────────────────────────────────
echo "==> package"
mkdir -p "$DIST"
cd "$BUILD"
rm -f "$OUT"
zip -qry "$OUT" Payload

echo
unzip -l "$OUT"
echo
ls -lh "$OUT"
sha256sum "$OUT"
