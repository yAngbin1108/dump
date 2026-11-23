//
//  SKCrashGuard.m
//  Blade — 让闪退留下痕迹
//

#import "SKCrashGuard.h"
#import "SKLog.h"

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

// 预先打开的日志 fd。信号处理器里只能用 async-signal-safe 的调用，
// write() 可以，SKLog()/NSLock/NSString 不行。
static int gCrashFd = -1;

static void crash_write(const char *s, size_t n) {
    if (gCrashFd >= 0 && n) {
        ssize_t ignored = write(gCrashFd, s, n);
        (void)ignored;
    }
}

static void crash_puts(const char *s) {
    if (s) crash_write(s, strlen(s));
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

static void crash_signal_handler(int sig) {
    const char *name = strsignal(sig);
    char hdr[160];
    int n = snprintf(hdr, sizeof(hdr),
                     "\n*** BLADE CRASH: signal %d (%s) ***\n", sig, name ? name : "?");
    if (n > 0) crash_write(hdr, (size_t)n);

    crash_puts("*** backtrace (most recent call first) ***\n");
    void *bt[80];
    int frames = backtrace(bt, 80);
    if (frames > 0) backtrace_symbols_fd(bt, frames, gCrashFd);

    // 恢复默认处理并重新抛，保留系统的崩溃行为（否则会看起来像正常退出）
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_signal(int sig) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(sig, &sa, NULL);
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
