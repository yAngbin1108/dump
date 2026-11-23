# dump

iOS 内核工具箱（AppDump / Blade 系）：砸壳、应用容器浏览、**进程管理**、文件管理器与**写权限修复**。

本仓库是在第三方 AppDump 源码的基础上，补上 **进程管理** 与 **修复写权限** 两个功能后的版本。
两个功能都来自上游 Blade 的实现（同一份内核层代码），这里只做了 UI 接入，没有改动利用链。

## 功能

| Tab | 内容 |
| --- | --- |
| 砸壳 | 运行利用链（VFS / SBX / Hybrid）、内核缓存管理、日志、设置 |
| 应用 | 已安装应用列表、图标、容器路径、FairPlay 砸壳为 IPA |
| **进程** | 内核 `allproc` 遍历出的进程列表（名称 / PID / UID / proc 地址）、搜索、结束进程、内存编辑器 |
| 文件 | 从 `/` 起的文件浏览器，长按 chmod / chown / 重命名 / 删除 / 分享 |

### 进程管理（新增）

`src/ProcessListViewController.{h,m}`

* 数据来自 `proclist()`（内核 `allproc` 链表遍历，需要先运行利用链）。
* 结束进程走 `killproc()`，写内核前取 `SKKernelLock()`，并且有二次确认 + 1.5 秒冷却
  （反复杀同一个进程会踩到已释放的 proc/thread）。
* 内存编辑进入 `SKMemoryEditorViewController`（h5gg 风格：搜索 / 读写）。
* 列表为空时区分两种情况：「内核原语未就绪」和「遍历失败」，不会让用户对着空白页猜。

### 修复写权限（新增）

`SKSandboxKeeper` 的 `+repairWriteAccessReportForPath:`，入口有两处：

* **设置 → 写权限 → 检查写权限 / 修复写权限**
* **文件管理器右上角省略号菜单 → 修复写权限**（就地修完继续操作）

做的事情分两层：

1. **MAC（沙盒）**：在 `/private/var/mobile/Library/Preferences` 上做 open/write/unlink 探针。
   失败说明内核把沙盒策略重新推导了一遍、内存里的编辑被冲掉 —— 用已有的内核读写原语
   重放一次 `sbx_escape()`（只改策略，不重跑利用链）。探针正常时零内核写。
2. **DAC（属主/权限）**：`SKEnsureWriteAccess` / `SKPermissionRepair` 把目标路径所属容器
   （或父目录）在内核里 chown 成 `mobile`，`_CodeSignature` / `SC_Info` 不动。

报告里会带上失败时的 `errno`，因为「策略没生效」和「文件本身不可写」只能靠它区分。

## 构建

GitHub Actions（macOS）自动构建，产物是 `dist/AppDump-arm64.ipa`：

    .github/workflows/build.yml → ci/build_ipa_macos.sh

本地也可以：

    bash ci/build_ipa_macos.sh        # 需要 Xcode + ldid

或者用仓库自带的 Linux 脚本（theos 工具链）：

    ./build_ipa.sh                    # dist/AppDump-arm64.ipa

签名是 ad-hoc + `src/appdump.entitlements`（platform-application 等私有权限）。
装到非越狱设备需要保留签名的安装方式（TrollStore / ESign 保留 entitlements）。

## 目录

    src/main.m                       tab 结构（砸壳 / 应用 / 进程 / 文件）
    src/ProcessListViewController.*  进程管理
    src/FileManager.*                文件管理器（控制台版）
    src/app/SKLaraFileBrowser.*      UIKit 文件浏览器 + 修复写权限菜单
    src/app/SKSandboxKeeper.*        沙盒策略保活 / 手动修复
    src/app/SKPermRepair.*           按需 chown
    src/app/SKAppOwn.*               容器属主修复
    src/kexploit/                    DarkSword 利用链
    ci/build_ipa_macos.sh            macOS 构建脚本

## 说明

仅用于研究自有设备。内核读写会写错内核数据，结束进程 / 内存编辑都有让系统重启的风险。