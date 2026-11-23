//
//  SKSandboxKeeper.m
//  SandboxKit — keep the sandbox escape's write permission alive
//
//  This implements the persistence design the user specified:
//
//    * After the escape, run a periodic background task.
//    * Every few seconds, probe whether write access is still present by
//      creating and writing a file on a system-privileged path.
//    * Success  -> do nothing.
//    * Failure  -> the kernel re-derived the policy from the on-disk profile;
//                  re-apply the sandbox policy edit using the kernel R/W
//                  primitive we already hold.
//
//  Invariants from that design, all of which matter:
//
//    * The periodic task ONLY re-writes the sandbox policy. It never re-runs
//      the exploit chain — re-exploiting risks a kernel panic, a plain memory
//      write does not.
//    * The probe must be on a privileged path, never inside our own container
//      (which is writable anyway and would prove nothing).
//    * sbx_escape() re-reads proc -> proc_ro -> ucred -> cr_label -> sandbox ->
//      ext_set from the kernel on every call. Nothing may be cached across
//      ticks, because the kernel can rebuild those structures at runtime.
//    * The re-apply must be idempotent so repeating it cannot corrupt an
//      already-corrected tree. sbx_escape() writes fixed values and the bucket
//      fill is a no-op once every slot is occupied.
//    * If the escape also elevated credentials, that has to be re-applied too,
//      because the kernel can restore them at the same time.
//
//  Interval: the spec calls for every 5-10 seconds. A probe is one syscall, so
//  the cost is negligible; the original 7 s is used.
//

#import "SKSandboxKeeper.h"
#import "SKLog.h"
#import "SKPermRepair.h"
#import "SKAppOwn.h"
#import "darksword.h"
#import "sbx.h"
#import "utils.h"
#import "SKKernelLock.h"

#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

// A system-privileged location. Deliberately NOT inside our own container:
// that is writable regardless of the escape, so it would tell us nothing.
static NSString * const kProbeDir  = @"/private/var/mobile/Library/Preferences";
static int gLastProbeErrno = 0;
static NSString * const kProbeFile = @"/private/var/mobile/Library/Preferences/.sbxkit_alive";

// 连续多少次自动重放都失败后就停手（避免在坏状态上没完没了地写内核）。
// 手动点"修复"不受这个上限约束 —— 那是用户明确要求的动作。
static const NSUInteger kMaxConsecutiveRepairFailures = 5;

@interface SKSandboxKeeper ()
@property (nonatomic, readwrite) BOOL running;
@property (nonatomic, readwrite) NSUInteger repairCount;
@property (nonatomic, readwrite) NSUInteger repairAttempts;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) BOOL accessLostReported;

// Consecutive sbx_escape() failures. The re-apply is a kernel write, not a
// re-exploit, so retrying is cheap — but "cheap" is not "free": once the sandbox
// has been rebuilt often enough that sbx_escape() can no longer recognise the
// extension set, every further attempt is another chance to write through a stale
// pointer. Stop hammering after a bounded number and say so.
@property (nonatomic, assign) NSUInteger consecutiveFailures;
@end

@implementation SKSandboxKeeper

+ (instancetype)sharedKeeper {
    static SKSandboxKeeper *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SKSandboxKeeper alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _interval = 7.0;
        _autoRepair = YES;
    }
    return self;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Probe
// ─────────────────────────────────────────────────────────────────────────────

// 失败时把 errno 带出来：EPERM 是沙盒策略拒绝，EACCES 是文件本身权限不够，
// EROFS/ENOSPC 又是另一回事。没有 errno 的话"写了但没恢复"完全无法区分。
+ (int)writeAccessProbeErrno {
    [self hasPrivilegedWriteAccess];
    return gLastProbeErrno;
}

+ (BOOL)hasPrivilegedWriteAccess {
    // open() on a privileged directory is not enough — read access can survive
    // while write access is gone, which is exactly the failure mode we are
    // detecting. Create + write + remove a file instead.
    const char *path = kProbeFile.UTF8String;

    errno = 0;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { gLastProbeErrno = errno; return NO; }

    const char marker[] = "alive\n";
    errno = 0;
    ssize_t n = write(fd, marker, sizeof(marker) - 1);
    int werr = errno;
    close(fd);
    unlink(path);
    gLastProbeErrno = (n == (ssize_t)(sizeof(marker) - 1)) ? 0 : werr;

    return gLastProbeErrno == 0;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Tick
// ─────────────────────────────────────────────────────────────────────────────

// 显式、用户发起的修复。
+ (BOOL)ensureWriteAccess {
    if ([self hasPrivilegedWriteAccess]) return YES;
    [[self sharedKeeper] repairNow];
    return [self hasPrivilegedWriteAccess];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Manual repair (UI)
// ─────────────────────────────────────────────────────────────────────────────

// 「修复写权限」按钮的实体。和周期任务共用同一条路径（repairNow → sbx_escape），
// 区别只有两点：手动修复不受连续失败上限约束（用户明确要求，就该再试一次），
// 并且会把每一步的结果拼成给用户看的报告 —— 失败时 errno 就是唯一线索。
+ (NSString *)repairWriteAccessReportForPath:(NSString *)path {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    if (!ds_is_ready()) {
        [lines addObject:@"内核读写原语未就绪。"];
        [lines addObject:@"先到「砸壳」页运行利用链，再回来修复写权限。"];
        return [lines componentsJoinedByString:@"\n"];
    }

    // 1) 沙盒策略（MAC 层）：/private/var/mobile 根本写不进去 = 逃逸被冲掉了。
    BOOL before = [self hasPrivilegedWriteAccess];
    if (before) {
        [lines addObject:@"沙盒策略：正常，/private/var/mobile 可写。"];
    } else {
        int e = [self writeAccessProbeErrno];
        [lines addObject:[NSString stringWithFormat:@"沙盒策略：已丢失（errno=%d %s）。",
                          e, strerror(e)]];
    }

    BOOL after = before;
    if (!before) {
        after = [self ensureWriteAccess];
        int e = [self writeAccessProbeErrno];
        if (after) {
            [lines addObject:@"已重放沙盒逃逸：写权限恢复。"];
        } else {
            [lines addObject:[NSString stringWithFormat:
                @"重放沙盒逃逸失败（errno=%d %s）。内核可能已经换了结构，重新运行利用链。",
                e, strerror(e)]];
        }
    } else {
        [lines addObject:@"无需重放沙盒逃逸（这次没有写内核）。"];
    }

    // 2) 属主/权限（DAC 层）：沙盒放行了，但文件不是 mobile 的照样 EACCES。
    if (path.length > 0) {
        NSString *display = path;
        BOOL dacOk = SKEnsureWriteAccess(path);
        if (!dacOk) dacOk = SKPermissionRepair(path);
        if (!dacOk) dacOk = SKPermissionRepairParent(path);
        if (!dacOk && access(path.fileSystemRepresentation, W_OK) == 0) dacOk = YES;

        [lines addObject:dacOk
            ? [NSString stringWithFormat:@"属主/权限：%@ 可写。", display.lastPathComponent]
            : [NSString stringWithFormat:@"属主/权限：%@ 仍不可写。", display]];
    }

    [lines addObject:@""];
    [lines addObject:after ? @"结论：写权限正常，可以继续操作文件。"
                           : @"结论：写权限仍不可用。"];
    return [lines componentsJoinedByString:@"\n"];
}

// 文件操作之后调用：探针丢了吗？丢了就补回来。
//
// 这是"写/删一个文件后权限必掉"的正面修复。写/删落盘时内核会重新处理扩展表，
// 我们在内核里改的那份"全局可读写"会被换回原样；这里立刻把状态探一遍，
// 只有真的丢了才重放逃逸 —— 没丢的话零内核写。
+ (BOOL)restoreIfLost:(NSString *)reason {
    if (!ds_is_ready()) return NO;
    if ([self hasPrivilegedWriteAccess]) return YES;   // 常态：什么都不做

    int e = [self writeAccessProbeErrno];
    // 先把「掉了什么」拍下来（纯只读），再决定怎么补。
    // 三种可能的真相（就地还原 / 节点被摘 / 表被重建）修法完全不同，
    // 日志里这四行就是判据。
    sbx_diag_compare(reason ? reason.UTF8String : "file-op");
    BOOL ok = [[self sharedKeeper] repairNow];
    SKLog(@"[keeper] %@ 之后写权限被内核冲掉(probe errno=%d %s)，自动重放逃逸: %@",
          reason ?: @"文件操作", e, strerror(e), ok ? @"已恢复" : @"失败");
    return ok;
}

// 周期性 tick：探针 → 丢了才重放。探针成功时绝不写内核。
//
// 早先这版是"只观察不写"，理由是一次自动重放连写 16 个扩展仍没恢复写权限，
// 于是只剩每 7 秒一次内核写。但那条日志属于旧的 patchchain 路径；现在
// ios16_sbx_escape 是定点改一条 extension，用户实测修复有效。
// 所以这里恢复成「探针失败才动手」，并加上连续失败上限，避免坏状态下打转。
- (BOOL)tick {
    if (!ds_is_ready()) {
        // No primitive yet; nothing we can do and nothing we should try.
        return NO;
    }

    if ([SKSandboxKeeper hasPrivilegedWriteAccess]) {
        self.accessLostReported = NO;
        self.consecutiveFailures = 0;
        return YES;
    }

    if (!self.autoRepair) {
        if (!self.accessLostReported) {
            self.accessLostReported = YES;
            [self emit:@"keeper: write access lost; auto-repair is OFF — tap repair to attempt it"];
        }
        return NO;
    }

    if (self.consecutiveFailures >= kMaxConsecutiveRepairFailures) {
        if (!self.accessLostReported) {
            self.accessLostReported = YES;
            [self emit:[NSString stringWithFormat:
                @"keeper: write access lost, and %lu automatic repairs failed in a row — "
                 "stopping auto-repair (避免在坏状态上反复写内核)",
                (unsigned long)self.consecutiveFailures]];
        }
        return NO;
    }

    self.accessLostReported = NO;
    return [self repairNow];
}

// The repair itself. Reached only from ensureWriteAccess(), i.e. only when the
// user taps repair — never from the timer.
- (BOOL)repairNow {
    if (!ds_is_ready()) return NO;

    self.repairAttempts += 1;

    uint64_t proc = ds_get_our_proc();
    if (proc == 0) proc = ourproc();

    // sbx_escape() reads and writes kernel memory; it must not run while a scan,
    // a decrypt or the .app ownership walk is using the primitive.
    [SKKernelLock() lock];
    int rc = sbx_escape(proc);
    [SKKernelLock() unlock];

    if (rc != 0) {
        self.consecutiveFailures += 1;
        [self emit:[NSString stringWithFormat:
            @"repair: sbx_escape rc=%d; write access not restored", rc]];
        return NO;
    }

    BOOL restored = [SKSandboxKeeper hasPrivilegedWriteAccess];
    self.accessLostReported = !restored;
    if (restored) {
        self.consecutiveFailures = 0;
        self.repairCount += 1;
        [self emit:[NSString stringWithFormat:@"repair: re-apply ok, probe=pass, repair #%lu",
            (unsigned long)self.repairCount]];
    } else {
        self.consecutiveFailures += 1;
        int e = [SKSandboxKeeper writeAccessProbeErrno];
        [self emit:[NSString stringWithFormat:
            @"repair: probe=fail errno=%d (%s), repair #%lu — sbx_escape 返回 0 但策略没生效",
            e, strerror(e), (unsigned long)self.repairCount]];
    }
    return restored;
}

// One sink only.
//
// This used to write SKLog() and also call onEvent, which the UI appended — the
// same string deliberately, so the two views could be correlated. That reasoning
// stopped holding once SKLog() gained a UI sink of its own: every keeper line,
// file and screen, went out twice. SKLog() is now the single path.
- (void)emit:(NSString *)msg {
    SKLog(@"[keeper] %@", msg);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)start {
    if (self.running) return;
    if (!ds_is_ready()) {
        [self emit:@"not starting: kernel primitive not up"];
        return;
    }

    NSTimeInterval iv = self.interval;
    if (iv < 3.0)  iv = 3.0;
    if (iv > 60.0) iv = 60.0;

    dispatch_queue_t q = dispatch_queue_create("sbxkit.keeper", DISPATCH_QUEUE_SERIAL);
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(self.timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(iv * NSEC_PER_SEC)),
                              (uint64_t)(iv * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        [weakSelf tick];
    });

    dispatch_resume(self.timer);
    self.running = YES;
    // No announcement. The keeper only observes now; "started (every 7s)" said
    // nothing a reader could act on.
}

- (void)stop {
    if (!self.running) return;
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
    self.running = NO;
    // Silent for the same reason.
}

@end
