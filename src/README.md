# Blade — 源码

iOS 内核工具箱：文件管理器、进程列表与内存编辑、砸壳（解密为 IPA）、应用图标列表与
容器属主修复、RemoteCall 跨进程调用。

## 这是什么格式

标准 **theos 工程**。目录顶层就是工程根：

    Makefile          theos 工程定义（ARCHS / FILES / FRAMEWORKS / LDFLAGS）
    control           deb 包元信息
    Info.plist        bundle 定义（CFBundleExecutable = blade）
    main.m  app/  kexploit/  locales/  LaunchScreen.storyboard
    build_ipa.sh      纯 Linux 构建脚本，不需要 macOS

## 编译

### 用 theos（推荐，跨平台）

    export THEOS=/opt/theos
    make            # 产出 .theos/obj/.../blade.app
    make package    # 产出 .deb

### 用自带的 Linux 脚本（只依赖 theos 工具链）

    ./build_ipa.sh              # arm64
    ./build_ipa.sh --arch arm64e   # 不要用，见下

产出 unsigned IPA 到 ./dist/。

## 两个必须知道的坑

### 1. 必须 arm64，不能 arm64e

目标设备是 iOS 17.5 / A16，直觉上该出 arm64e，但 **arm64e 的包打开就黑屏闪退**，
arm64 能跑。arm64 在 arm64e 设备上向后兼容，功能不受影响。

两套 ABI 在二进制里的区别可以直接看出来：

    arm64e   cpusubtype 0x80000002   __auth_stubs + __auth_got   format 12
    arm64    cpusubtype 0x00000000   __stubs      + __got        format  6

### 2. 链接器

只装 theos 就够了。theos 自带的 ld64-609 默认会输出老式
`LC_DYLD_INFO` 绑定/重定位，构建脚本里加了 `-Wl,-fixup_chains`，
让它输出现代 chained fixups（指针数量与 Apple ld64-956 的产物完全一致，
只是声明的 pointer_format 是 2 而不是 6 —— 这个格式在目标设备上可用，
`libgrabkernel2.dylib` 的 arm64 slice 本来就是格式 2）。

完整的 Linux 工具链路径写死在 `build_ipa.sh` 顶部：

    TC="/opt/theos/toolchain/linux/iphone/bin"
    SDK="/opt/theos/sdks/iPhoneOS16.5.sdk"

## 源码清单

    main.m                          终端风格主界面
    FileManager.{h,m}               文件浏览器
    ProcessListViewController.{h,m} 进程列表
    Exploit.{h,m}                   利用链封装
    app/SKAppBrowser.{h,m}          应用列表（图标 / 容器路径 / 砸壳入口）
    app/SKDecryptUI.{h,m}           砸壳界面
    app/SKZipWriter.{h,m}           IPA 打包
    app/SKMemoryEditor.{h,m}        h5gg 风格内存编辑器
    app/SKOverlay.{h,m}             RemoteCall 悬浮窗
    app/SKAppOwn.{h,m}              容器属主修复
    app/SKFileWriter.{h,m}          root 写入辅助
    app/SKLog.{h,m}                 日志
    app/SKDiag.{h,m}                崩溃与 panic 日志收集
    app/SKSandboxKeeper.{h,m}       周期性重放沙盒策略
    kexploit/                       DarkSword 链
    kexploit/lib/                   libgrabkernel2.dylib, libxpf.dylib
    locales/                        en zh-Hans zh-Hant ja ko

## 签名

构建脚本用 `ldid -S` 做 ad-hoc 签名，**不含任何 entitlements**。
装到非越狱设备上需要你自己用证书重签。
