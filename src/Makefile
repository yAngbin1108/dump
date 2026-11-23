# Blade — theos project
#
#   make            -> .theos/obj/.../blade.app
#   make package    -> .deb
#   ./build_ipa.sh  -> unsigned .ipa, no macOS needed
#
# ARCHS is arm64, NOT arm64e. The arm64e builds of this app crashed on launch on
# the target device (iOS 17.5 / A16) while the arm64 builds ran. Blade5 onward
# are all arm64. See README.md.

ARCHS = arm64
TARGET = iphone:clang:16.5:15.0

APPLICATION_NAME = blade

blade_FILES = main.m FileManager.m Exploit.m ProcessListViewController.m \
	$(wildcard app/*.m) \
	kexploit/darksword.m \
	kexploit/offsets.m \
	kexploit/utils.m \
	kexploit/persistence.m \
	kexploit/decrypt.m \
	kexploit/TaskRop/RemoteCall.m \
	kexploit/TaskRop/thread.m \
	kexploit/TaskRop/vm.m \
	kexploit/TaskRop/pac.m \
	kexploit/TaskRop/exc.m \
	kexploit/TaskRop/findcachedataoff.m \
	kexploit/pe/sbx.m \
	kexploit/pe/vnode.m \
	kexploit/pe/vfs.m \
	kexploit/pe/apfs.m

blade_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore \
	AVFoundation AVKit CoreFoundation Security IOSurface

blade_CFLAGS = -fobjc-arc -fno-modules \
	-Wno-error=deprecated-declarations -Wno-unused-function -Wno-nullability \
	-I./kexploit -I./kexploit/pe -I./kexploit/TaskRop \
	-I./kexploit/headers -I./kexploit/xpc -I./app

blade_LDFLAGS = -L./kexploit/lib -lgrabkernel2 -lxpf -lz \
	-Wl,-rpath,@executable_path/Frameworks

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	@set -e; \
	OBJDIR="$(THEOS_OBJ_DIR)"; \
	DST="$(THEOS_STAGING_DIR)/Applications/blade.app"; \
	LDID="$$(command -v ldid || echo "$(THEOS)/toolchain/linux/iphone/bin/ldid")"; \
	BIN="$$OBJDIR/blade.app/blade"; \
	[ -f "$$BIN" ] || BIN="$$OBJDIR/arm64/blade.app/blade"; \
	rm -rf "$$DST"; mkdir -p "$$DST/Frameworks"; \
	cp "$$BIN" "$$DST/blade"; chmod +x "$$DST/blade"; \
	cp Info.plist "$$DST/Info.plist"; \
	cp LaunchScreen.storyboard "$$DST/LaunchScreen.storyboard"; \
	printf 'APPL????' > "$$DST/PkgInfo"; \
	for d in locales/*.lproj; do cp -R "$$d" "$$DST/"; done; \
	cp kexploit/lib/libgrabkernel2.dylib "$$DST/Frameworks/"; \
	cp kexploit/lib/libxpf.dylib         "$$DST/Frameworks/"; \
	chmod +x "$$DST/Frameworks/"*.dylib; \
	"$$LDID" -S "$$DST/blade" 2>/dev/null || true; \
	"$$LDID" -S "$$DST/Frameworks/libgrabkernel2.dylib" 2>/dev/null || true; \
	"$$LDID" -S "$$DST/Frameworks/libxpf.dylib" 2>/dev/null || true; \
	echo "==> $$DST assembled"
