#!/bin/bash
#
# ci/build_ipa_macos.sh — 在 macOS（GitHub Actions）上构建 AppDump.ipa
#
# 和仓库自带的 build_ipa.sh 是同一件事，只是把 Linux/theos 工具链换成了
# Xcode 自带的 clang + iPhoneOS SDK：
#
#   build_ipa.sh        Linux + /opt/theos 的 clang-11 / sdks/iPhoneOS16.5.sdk
#   本脚本              macOS + xcrun --sdk iphoneos（不需要 theos）
#
# 编译参数、源文件清单、包的布局、entitlements 都与 build_ipa.sh 保持一致，
# 唯一的差别是架构只出 arm64（和设备上验证过的那份一致）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
OUTNAME="AppDump"
APP="appdump"
ARCH="${ARCH:-arm64}"
MIN_IOS="15.0"

APPDIR="$BUILD/Payload/$OUTNAME.app"
OUT="$DIST/$OUTNAME-$ARCH.ipa"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
echo "==> sdk   $SDK"
echo "==> clang $CLANG"

echo "==> clean"
rm -rf "$BUILD"
mkdir -p "$APPDIR/Frameworks" "$DIST"

# ── 源文件（与 build_ipa.sh 的列表一致）────────────────────────────────────
SRCS=()
while IFS= read -r rel; do
  [ -f "$SRC/$rel" ] && SRCS+=("$SRC/$rel")
done <<'LIST'
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
kexploit/skcydowngrade.m
kexploit/skblockupdates.m
kexploit/pe/sbx.m
kexploit/cyremote.m
kexploit/pe/vfs.m
kexploit/pe/apfs.m
LIST

# app/*.m 全部编译（SKDiag.m 在 macOS 构建里也编进来，它只做日志收集）
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$SRC/app" -name '*.m' | sort)

INCLUDES=(
  -I"$SRC"
  -I"$SRC/kexploit"
  -I"$SRC/kexploit/cy"
  -I"$SRC/kexploit/pe"
  -I"$SRC/kexploit/TaskRop"
  -I"$SRC/kexploit/headers"
  -I"$SRC/kexploit/xpc"
  -I"$SRC/app"
  -I"$SRC/vendor/cyanide"
)

CFLAGS=(
  -target "${ARCH}-apple-ios${MIN_IOS}"
  -isysroot "$SDK"
  -miphoneos-version-min=${MIN_IOS}
  -fobjc-arc
  -fmodules
  -fobjc-legacy-dispatch
  -O2
  -Wno-everything
)

FRAMEWORKS=(
  -framework UIKit -framework Foundation -framework CoreGraphics
  -framework QuartzCore -framework AVFoundation -framework AVKit -framework WebKit
  -framework CoreFoundation -framework Security -framework IOSurface
)

LIBS=( -L"$SRC/kexploit/lib" -lgrabkernel2 -lxpf -lz )

# ── vendored Cyanide TaskRop ────────────────────────────────────────────────
# 原样编译 src/vendor/cyanide/TaskRop/*.m，只在编译期用 cy_prefix.h 加前缀，
# 避免和 dump 自己的 kexploit/TaskRop 撞符号（两套实现要并存）。
VENDOR_SRCS=()
for f in "$SRC/vendor/cyanide/TaskRop"/*.m; do
  [ -f "$f" ] && VENDOR_SRCS+=("$f")
done

# ── 编译 ────────────────────────────────────────────────────────────────────
echo "==> compile (${#SRCS[@]} files)"
OBJDIR="$BUILD/obj"; mkdir -p "$OBJDIR"
OBJS=()
for s in "${SRCS[@]}"; do
  rel="${s#$SRC/}"
  o="$OBJDIR/$(echo "$rel" | tr '/' '_' | sed -e 's/\.m$/.o/')"
  echo "    CC $rel"
  "$CLANG" "${CFLAGS[@]}" "${INCLUDES[@]}" -c "$s" -o "$o"
  OBJS+=("$o")
done

echo "==> compile vendored Cyanide (${#VENDOR_SRCS[@]} files)"
for s in "${VENDOR_SRCS[@]}"; do
  rel="${s#$SRC/}"
  o="$OBJDIR/vendor_$(echo "$rel" | tr '/' '_' | sed -e 's/\.m$/.o/')"
  echo "    CC $rel"
  "$CLANG" "${CFLAGS[@]}" "${INCLUDES[@]}" \
    -include "$SRC/vendor/cyanide/cy_prefix.h" -c "$s" -o "$o"
  OBJS+=("$o")
done

# ── 链接 ────────────────────────────────────────────────────────────────────
echo "==> link"
"$CLANG" "${CFLAGS[@]}" "${OBJS[@]}" "${FRAMEWORKS[@]}" "${LIBS[@]}" \
  -Wl,-rpath,@executable_path/Frameworks \
  -o "$APPDIR/$APP"
file "$APPDIR/$APP" || true

# ── 打包 bundle ─────────────────────────────────────────────────────────────
echo "==> bundle"
for d in "$SRC"/locales/*.lproj; do
  [ -d "$d" ] || continue
  cp -R "$d" "$APPDIR/"
done

if [ -d "$SRC/icons" ]; then
  for f in "$SRC"/icons/*.png; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in AppIcon-1024.png) continue ;; esac
    cp "$f" "$APPDIR/"
  done
fi

cp "$SRC/Info.plist"             "$APPDIR/Info.plist"
cp "$SRC/LaunchScreen.storyboard" "$APPDIR/LaunchScreen.storyboard"
printf 'APPL????'                > "$APPDIR/PkgInfo"

cp "$SRC/kexploit/lib/libgrabkernel2.dylib" "$APPDIR/Frameworks/"
cp "$SRC/kexploit/lib/libxpf.dylib"         "$APPDIR/Frameworks/"
chmod +x "$APPDIR/Frameworks/"*.dylib

# ── 签名：ldid（保留私有 entitlements），没有就退回 ad-hoc codesign ───────
ENT="$SRC/appdump.entitlements"
echo "==> sign"
if command -v ldid >/dev/null 2>&1; then
  for lib in libgrabkernel2.dylib libxpf.dylib; do
    ldid -S"$ENT" "$APPDIR/Frameworks/$lib" 2>/dev/null || ldid -S "$APPDIR/Frameworks/$lib" || true
  done
  ldid -S"$ENT" "$APPDIR/$APP" 2>/dev/null || ldid -S "$APPDIR/$APP"
else
  for lib in libgrabkernel2.dylib libxpf.dylib; do
    codesign -f -s - "$APPDIR/Frameworks/$lib" || true
  done
  codesign -f -s - --entitlements "$ENT" "$APPDIR/$APP"
fi

# ── 打包 IPA ────────────────────────────────────────────────────────────────
echo "==> package"
cd "$BUILD"
rm -f "$OUT"
zip -qry "$OUT" Payload

echo
unzip -l "$OUT" | tail -20
echo
ls -lh "$OUT"
shasum -a 256 "$OUT"