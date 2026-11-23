# dump

iOS 内核工具箱（AppDump / Blade 系）：砸壳、应用容器浏览、**工具页（进程管理 / 应用降级 / 阻止更新）**、
文件管理器与**写权限修复**。

本仓库是在第三方 AppDump 源码的基础上，补上 **进程管理**、**修复写权限**、**应用降级**、
**阻止应用更新** 后的版本。前两个来自上游 Blade 的实现，后两个从 Cyanide 移植
（注入 SpringBoard / installd 的做法），内核层接口接在本仓库的 TaskRop RemoteCall 上。

## 功能

| Tab | 内容 |
| --- | --- |
| 砸壳 | 运行利用链（VFS / SBX / Hybrid）、内核缓存管理、日志、设置 |
| 应用 | 已安装应用列表、图标、容器路径、FairPlay 砸壳为 IPA |
| **工具** | 进程管理、应用降级、阻止应用更新（三个入口收在同一页） |
| 文件 | 从 `/` 起的文件浏览器，长按 chmod / chown / 重命名 / 删除 / 分享 |

### 进程管理

入口：**工具 → 进程管理**。`src/ProcessListViewController.{h,m}`

* 数据来自 `proclist()`（内核 `allproc` 链表遍历，需要先运行利用链）。
* 结束进程走 `killproc()`，写内核前取 `SKKernelLock()`，并且有二次确认 + 1.5 秒冷却
  （反复杀同一个进程会踩到已释放的 proc/thread）。
* 内存编辑进入 `SKMemoryEditorViewController`（h5gg 风格：搜索 / 读写）。
* 列表为空时区分两种情况：「内核原语未就绪」和「遍历失败」，不会让用户对着空白页猜。

### 应用降级（新增）

`src/kexploit/skdowngrade.{h,m}` + `src/app/SKDowngradeViewController.{h,m}`

* 选应用 → 用 iTunes lookup 多区兜底查 `trackId` → 从
  `apis.bilin.eu.org/history/<trackId>` 取历史版本 → 选 `external_identifier`。
* 执行时注入 **SpringBoard**：`dlopen` StoreKitUI，构造 `SKUIItem` /
  `SKUIItemOffer`，KVC 写 `_itemOffer` / `_itemKindString` / `_versionIdentifier`，
  再用 `SKUIItemStateCenter` 的 `_newPurchasesWithItems:` +
  `_performPurchases:hasBundlePurchase:withClientContext:completionBlock:` 提交请求。
* `buyParameters` 里带 `appExtVrsId=<目标版本>`，商店就会按那个版本下发。
* 两个容易白提交的细节：lookup 字典优先用 iTunes 原始条目（否则 `itemIdentifier`
  为 0，商店不报错也不下载）；`SKUIClientContext defaultContext` 为空时退空白实例。
* 也可以绕过版本接口，直接手填 external_identifier。

### 阻止应用更新（新增）

`src/kexploit/skblockupdates.{h,m}` + `src/app/SKBlockUpdatesViewController.{h,m}`

* 注入 **installd**，在 `.app` 的父目录建立
  `com.apple.mobileinstallation.placeholder`（目录，权限 `0000`）：安装服务会把该应用
  当成「正在安装」，从而跳过更新。恢复时 `chmod 0755` + `rmdir`。
* installd 平时休眠，需要用户先去 App Store 点任意 App 的「获取」唤醒；代码每 2 秒
  重试，最长约 2 分钟，日志页会持续提示。
* 列表里直接显示每个应用当前是否已被阻止。

> 这两个功能都要在别的进程里执行代码，**必须 arm64e 构建**（RemoteCall 需要 pacia
> 签名的 PC/LR）。arm64 包里会明确提示「当前为 arm64 构建」，不会静默失败。

### 修复写权限

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

GitHub Actions（macOS）自动构建，产物是 `dist/AppDump-arm64.ipa` 与
`dist/AppDump-arm64e.ipa`（降级 / 阻止更新需要 arm64e）：

    .github/workflows/build.yml → ci/build_ipa_macos.sh
    ARCH=arm64e bash ci/build_ipa_macos.sh

本地也可以：

    bash ci/build_ipa_macos.sh        # 需要 Xcode + ldid（默认 arm64）

或者用仓库自带的 Linux 脚本（theos 工具链）：

    ./build_ipa.sh                    # dist/AppDump-arm64.ipa

签名是 ad-hoc + `src/appdump.entitlements`（platform-application 等私有权限）。
装到非越狱设备需要保留签名的安装方式（TrollStore / ESign 保留 entitlements）。

## 目录

    src/main.m                       tab 结构（砸壳 / 应用 / 工具 / 文件）
    src/ProcessListViewController.*  进程管理
    src/app/SKToolsViewController.*  工具页（三个入口）
    src/app/SKDowngradeViewController.*  应用降级 UI（版本查询 / 选择 / 执行）
    src/app/SKBlockUpdatesViewController.*  阻止更新 UI（多选 / 进度）
    src/app/SKToolApps.*             应用列表（两个功能共用）
    src/kexploit/skrc.*              RemoteCall 会话封装（线程内 + SKKernelLock）
    src/kexploit/skdowngrade.*       注入 SpringBoard 提交历史版本
    src/kexploit/skblockupdates.*    注入 installd 管理 placeholder
    src/FileManager.*                文件管理器（控制台版）
    src/app/SKLaraFileBrowser.*      UIKit 文件浏览器 + 修复写权限菜单
    src/app/SKSandboxKeeper.*        沙盒策略保活 / 手动修复
    src/app/SKPermRepair.*           按需 chown
    src/app/SKAppOwn.*               容器属主修复
    src/kexploit/                    DarkSword 利用链
    ci/build_ipa_macos.sh            macOS 构建脚本

## 说明

仅用于研究自有设备。内核读写会写错内核数据，结束进程 / 内存编辑都有让系统重启的风险。