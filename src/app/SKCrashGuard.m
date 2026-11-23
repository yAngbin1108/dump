//
//  SKCrashGuard.m
//  Blade — 让闪退留下痕迹（含注入窗口保护）
//

#import "SKCrashGuard.h"
#import "SKLog.h"

#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

// 预先打开的日志 fd。信号处理器里只能用 async-signal-safe 的调用，
// write() 可以，SKLog()/NSLock/NSString 不行。
static int gCrashFd = -1;

// 注入窗口（可嵌套）。signal handler 里只读这个 sig_atomic_t。
static volatile sig_atomic_t gInjectionDepth = 0;
// 最近一次 park 的信息（write() 到日志用，普通变量即可）
static char gParkedReason[160];

static void crash_write(const char *s, size_t n) {
    if (gCrashFd >= 0 && n) {
        ssize_t ignored = write(gCrashFd, s, n);
        (void)ignored;
    }
}

static void crash_puts(const char *s) {
    if (s) crash_write(s, strlen(s));
}

/// 把当前线程永久停在这里。只有 async-signal-safe 的 pause()。
static void sk_park_forever(void) {
    for (;;) pause();
}

// 未捕获异常处理器：这里处于正常上下文（不是信号上下文），可以用 NSString。
static void crash_exception_handler(NSException *ex) {
    char buf[1024];
    int n = snprintf(buf, sizeof(buf),
                     "\n*** BLADE UNCAUGHT EXCEPTION: %s ***\n*** reason: %s ***\n",
                     (ex.name ?: @"?").UTF8String,
                     (ex.reason ?: @"?").UTF8String);
    if (n > 0) crash_write(buf, (size_t)n);
    crash_puts("*** call stack ***\n");
    for (NSString *line in ex.callStackSymbols) {
        crash_puts(line.UTF8String);
        crash_puts("\n");
    }
}

static void crash_log_backtrace(int sig) {
    const char *name = strsignal(sig);
    char hdr[160];
    int n = snprintf(hdr, sizeof(hdr),
                     "\n*** BLADE CRASH: signal %d (%s) ***\n", sig, name ? name : "?");
    if (n > 0) crash_write(hdr, (size_t)n);

    crash_puts("*** backtrace (most recent call first) ***\n");
    void *bt[80];
    int frames = backtrace(bt, 80);
    if (frames > 0) backtrace_symbols_fd(bt, frames, gCrashFd);
}

static void crash_signal_handler(int sig, siginfo_t *info, void *uctx) {
    (void)info;

    // ── 注入窗口 ────────────────────────────────────────────────────────
    // RemoteCall 在 iOS 17 上会在注入线程里踩到 0xffffffffffffffff，
    // 这时候线程状态已经没救了，但把这条线程停住、让 App 活着，
    // 用户至少能看到日志里的失败原因，而不是整个 App 消失。
    if (gInjectionDepth > 0 && !pthread_main_np()
        && (sig == SIGBUS || sig == SIGSEGV || sig == SIGILL || sig == SIGTRAP)) {
        gInjectionDepth = 0;
        int n = snprintf(gParkedReason, sizeof(gParkedReason),
                         "*** BLADE: injection-window signal %d (%s), thread parked ***\n",
                         sig, strsignal(sig) ?: "?");
        if (n > 0) crash_write(gParkedReason, (size_t)n);
        crash_puts("*** thread parked, process kept alive ***\n");

#if defined(__arm64__)
        // 不 include <ucontext.h>：它在 iOS SDK 里需要 _XOPEN_SOURCE，而我们这里
        // 只用一个固定布局（arm64 上稳定）：
        //   struct __darwin_ucontext: uc_mcontext @ +48
        //   struct __darwin_mcontext64: __ss @ +16
        //   __darwin_arm_thread_state64: lr @ +240, sp @ +248, pc @ +256
        uint8_t *uc = (uint8_t *)uctx;
        if (uc) {
            uintptr_t mctx = *(uintptr_t *)(uc + 48);
            if (mctx) {
                uint8_t *ss = (uint8_t *)mctx + 16;
                *(uintptr_t *)(ss + 240) = (uintptr_t)sk_park_forever;   // lr
                *(uintptr_t *)(ss + 256) = (uintptr_t)sk_park_forever;   // pc
            }
        }
#endif
        return;   // 不 re-raise：返回后内核跳到 __pc（死循环）
    }

    crash_log_backtrace(sig);

    // 恢复默认处理并重新抛，保留系统的崩溃行为（否则会看起来像正常退出）
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_signal(int sig) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigaction(sig, &sa, NULL);
}

void SKCrashGuardBeginInjectionWindow(void) {
    gInjectionDepth++;
}

void SKCrashGuardEndInjectionWindow(void) {
    if (gInjectionDepth > 0) gInjectionDepth--;
}

NSString *SKCrashGuardLastParkedReason(void) {
    if (gParkedReason[0] == '\0') return nil;
    return [NSString stringWithUTF8String:gParkedReason];
}

void SKCrashGuardInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = SKLogPath();
        if (path.length) {
            gCrashFd = open(path.fileSystemRepresentation,
                            O_WRONLY | O_APPEND | O_CREAT, 0644);
        }

        // 未捕获的 ObjC 异常。set_target_kaddr 的 @throw 走的就是这条路 ——
        // 以前它只会让进程无声消失。
        NSSetUncaughtExceptionHandler(crash_exception_handler);

        install_signal(SIGABRT);
        install_signal(SIGSEGV);
        install_signal(SIGBUS);
        install_signal(SIGILL);
        install_signal(SIGFPE);
        install_signal(SIGTRAP);
    });
}
