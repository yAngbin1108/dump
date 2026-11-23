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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安装崩溃钩子。必须在任何可能崩溃的代码之前调用（main 最开头）。
void SKCrashGuardInstall(void);

NS_ASSUME_NONNULL_END
