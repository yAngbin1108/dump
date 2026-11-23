//
//  SKCrashGuard.h
//  Blade — 让闪退留下痕迹
//
//  问题：Blade 崩的时候 sk.log 停在最后一行正常日志上，什么线索都没有，设备上
//  也没有 CrashReporter 目录可以取。于是每次闪退都只能靠读代码猜。
//
//  这里装两个钩子：
//    * NSSetUncaughtExceptionHandler —— 未捕获的 ObjC 异常（例如
//      set_target_kaddr 地址不合规时抛的那个），把 name/reason/调用栈写进日志；
//    * signal handler —— SIGSEGV/SIGABRT/SIGBUS 等信号，用 write() 写日志 +
//      backtrace_symbols_fd() 打调用栈。
//
//  信号处理器里只能用 async-signal-safe 的东西：write() 和
//  backtrace_symbols_fd() 可以，NSLock/NSString 不行 —— 所以这条路绕开 SKLog。
//
//  ── 注入窗口 ───────────────────────────────────────────────────────────
//  RemoteCall 在 iOS 17 上会在注入线程里踩到被内核毒化的地址（pc/lr 全是
//  0xffffffffffffffff），正常处理就是整个 App 被带走。降级/阻止更新这类
//  「可能失败」的注入操作前后调用 SKCrashGuardBegin/EndInjectionWindow()，
//  窗口内非主线程的 BUS/SEGV/ILL/TRAP 只把这条线程停住（park），进程继续，
//  日志里能看到失败原因，用户不用重开 App。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安装崩溃钩子。必须在任何可能崩溃的代码之前调用（main 最开头）。
void SKCrashGuardInstall(void);

/// 打开/关闭注入窗口（可嵌套，计数）。
void SKCrashGuardBeginInjectionWindow(void);
void SKCrashGuardEndInjectionWindow(void);

/// 最近一次被 park 的线程信息（调试/界面提示用）。
NSString * _Nullable SKCrashGuardLastParkedReason(void);

NS_ASSUME_NONNULL_END
