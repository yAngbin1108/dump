//
//  SKLog.m
//  Blade
//

#import "SKLog.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// Keep the file bounded; the interesting part is always the tail.
static const long long kSKLogMaxBytes = 256 * 1024;

static FILE *gSKLogFile = NULL;
static long long gSKLogBytes = 0;
static NSLock *gSKLogLock = nil;
static SKLogSinkBlock gSKLogSink = nil;
static NSMutableArray<NSString *> *gSKRecent = nil;   // guarded by gSKLogLock
static const NSUInteger kSKRecentMax = 800;

static FILE *sk_open(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > kSKLogMaxBytes) {
        unlink(path);                   // start clean once it gets big
    }
    FILE *f = fopen(path, "a");
    if (f) setvbuf(f, NULL, _IOLBF, 0);
    return f;
}

static void sk_log_open(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    if (docs.length) {
        NSString *path = [docs stringByAppendingPathComponent:@"sk.log"];
        gSKLogFile = sk_open(path.fileSystemRepresentation);
        if (gSKLogFile) {
            struct stat st;
            gSKLogBytes = (fstat(fileno(gSKLogFile), &st) == 0) ? (long long)st.st_size : 0;
        }
    }
}

static void sk_log_ensure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSKLogLock = [[NSLock alloc] init];
        gSKRecent = [NSMutableArray array];
        sk_log_open();
    });
}

NSArray<NSString *> *SKLogRecentLines(void) {
    sk_log_ensure();
    [gSKLogLock lock];
    NSArray *out = gSKRecent ? [gSKRecent copy] : @[];
    [gSKLogLock unlock];
    return out;
}

void SKLogClearRecentLines(void) {
    sk_log_ensure();
    [gSKLogLock lock];
    [gSKRecent removeAllObjects];
    [gSKLogLock unlock];
}

NSString *SKLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return docs.length ? [docs stringByAppendingPathComponent:@"sk.log"] : @"(no Documents)";
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - stdout / stderr capture
// ─────────────────────────────────────────────────────────────────────────────
//
// See SKLog.h. Two details worth stating because they are the failure modes:
//
//   * The reader runs on its own thread and must never exit early. If it stops
//     draining, the pipe fills, and the next printf() blocks — the exploit
//     would hang rather than fail, which is far worse than losing output.
//
//   * SKLog() itself writes to a FILE, never to stdout, so logging from the
//     reader cannot recurse. That is the only reason this is safe.

#include <dispatch/dispatch.h>
#include <string.h>

static int gSKStdoutPipe[2] = { -1, -1 };
static dispatch_once_t gSKStdoutOnce;

// printf() output is C strings, and most of it is ASCII, but a line that is not
// valid UTF-8 must still be logged rather than dropped. Latin-1 never fails.
static NSString *sk_decode(const char *buf, size_t len) {
    NSString *s = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    if (s) return s;
    return [[NSString alloc] initWithBytes:buf length:len encoding:NSISOLatin1StringEncoding] ?: @"";
}

static void sk_drain_pipe(int fd) {
    char buf[1024];
    NSMutableString *pending = [NSMutableString string];

    // 这个循环永远不能退出。以前 read() 返回 <= 0 就 break —— 一次 EINTR
    // （进程里随时会有信号，砸壳那几个阶段尤其多）就足以让 drain 线程永久消失：
    // 之后管里没人读，管道 16 KB 满了以后，下一个 printf/fprintf(stderr) 就
    // 永久阻塞，正在砸壳的那个线程就卡死在自己的一行日志上 —— 拉起请求可能
    // 根本发不出去，表现成"拉不起来 / 砸壳没反应"。所以：EINTR/EAGAIN 继续，
    // 其余错误也继续（睡眠一下再来），永远不 return。
    for (;;) {
        @autoreleasepool {
            ssize_t n = read(fd, buf, sizeof(buf) - 1);
            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
                // fd 被破坏之类：睡一下再看，总之不能退出。
                usleep(200 * 1000);
                continue;
            }
            if (n == 0) {          // 写端都关了，同样不能退出
                usleep(200 * 1000);
                continue;
            }

            [pending appendString:sk_decode(buf, (size_t)n)];

            NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [pending substringToIndex:nl.location];
                [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                if (line.length) SKLog(@"[out] %@", line);
            }
            // A line that never ends would grow without bound.
            if (pending.length > 8192) {
                SKLog(@"[out] %@", pending);
                [pending setString:@""];
            }
        }
    }
    if (pending.length) SKLog(@"[out] %@", pending);
}

void SKLogCaptureStdout(void) {
    dispatch_once(&gSKStdoutOnce, ^{
        if (pipe(gSKStdoutPipe) != 0) return;

        fflush(stdout);
        fflush(stderr);

        dup2(gSKStdoutPipe[1], STDOUT_FILENO);
        dup2(gSKStdoutPipe[1], STDERR_FILENO);
        close(gSKStdoutPipe[1]);
        gSKStdoutPipe[1] = -1;

        // Line buffered: the chain calls fflush() after most writes, but not all.
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IOLBF, 0);

        int fd = gSKStdoutPipe[0];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            sk_drain_pipe(fd);
        });
    });
}

void SKLog(NSString *fmt, ...) {
    sk_log_ensure();

    if (!gSKLogFile) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    // Fixed-format timestamp: avoids NSDateFormatter cost on every line.
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    time_t secs = tv.tv_sec;
    localtime_r(&secs, &tmv);

    [gSKLogLock lock];
    char line[4096];
    snprintf(line, sizeof(line), "%02d:%02d:%02d.%03d  %s\n",
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000),
             msg.UTF8String ?: "");
    if (gSKLogFile) {
        // 上限以前只在打开文件时检查一次，所以一次会话里可以无限长下去
        // （砸壳时每个镜像、每个 entry 都写日志）。写入路径上再查一次。
        if (gSKLogBytes > kSKLogMaxBytes) {
            fflush(gSKLogFile);
            if (ftruncate(fileno(gSKLogFile), 0) == 0) gSKLogBytes = 0;
        }
        fputs(line, gSKLogFile);
        fflush(gSKLogFile);
        gSKLogBytes += (long long)strlen(line);
    }

    if (gSKRecent) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        [gSKRecent addObject:@(line)];
        if (gSKRecent.count > kSKRecentMax)
            [gSKRecent removeObjectsInRange:NSMakeRange(0, gSKRecent.count - kSKRecentMax)];
    }
    [gSKLogLock unlock];

    // Feed the UI as well. Outside the file lock on purpose: the sink marshals to
    // the main thread, and holding this lock across that hop would block every
    // other logger behind the UI.
    SKLogSinkBlock sink = gSKLogSink;
    if (sink) sink(msg);
}

void SKLogSetSink(SKLogSinkBlock sink) {
    gSKLogSink = sink;
}
