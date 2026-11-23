//
//  SKSandboxKeeper.h
//  SandboxKit — keep the sandbox escape's write permission alive
//
//  PROBLEM
//  -------
//  The sandbox escape works by editing the process's sandbox policy in kernel
//  memory. That edit is volatile: when the kernel's security services re-derive
//  policy from the on-disk profile (on a privileged-path write, an IPC event, a
//  credential recompute), the in-memory edit is overwritten and write access is
//  lost. Reopening the app or re-running the exploit restores it, but re-running
//  the exploit is the risky part and must be avoided.
//
//  APPROACH
//  --------
//  The kernel R/W primitive itself is durable — it lives on an in-kernel socket
//  structure and stays valid as long as the process and socket survive. Only the
//  policy edit is volatile. So a cheap background loop periodically checks
//  whether write access is still present and, if it is not, re-applies just the
//  policy edit through the existing primitive.
//
//  INVARIANTS (from the persistence design this implements)
//  ----------
//  * The periodic task ONLY re-writes the sandbox policy. It never re-runs the
//    exploit chain: re-exploiting risks a kernel panic, a plain memory write
//    does not.
//  * The probe is on a system-privileged path, never inside our own container
//    (which is writable anyway and would prove nothing).
//  * sbx_escape() re-reads proc -> proc_ro -> ucred -> cr_label -> sandbox ->
//    ext_set from the kernel on every call, so a structure the kernel rebuilt at
//    runtime is picked up. Nothing is cached across ticks.
//  * The re-apply is idempotent: it writes fixed values, so repeating it cannot
//    corrupt an already-corrected tree.
//  * A failed re-apply is retried on the next tick. That is deliberate — the
//    whole point is that the kernel keeps restoring the policy, and repairing is
//    cheap. An earlier revision capped this at one attempt and stopped on
//    failure, which defeated the design.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN


@interface SKSandboxKeeper : NSObject

+ (instancetype)sharedKeeper;

/// Whether the periodic task is running.
@property (nonatomic, readonly) BOOL running;

/// Number of times write access was lost and successfully re-applied.
@property (nonatomic, readonly) NSUInteger repairCount;

/// Number of automatic repair attempts made (successful or not). Bounded by the
/// hard cap described above; when it reaches the cap the keeper stops writing
/// the kernel entirely.
@property (nonatomic, readonly) NSUInteger repairAttempts;

/// Seconds between probes. Clamped to [3, 300]; default 30.
@property (nonatomic, assign) NSTimeInterval interval;

/// Start the periodic task. Safe to call repeatedly; does nothing if already
/// running or if the kernel primitive is not up.
- (void)start;

/// Stop the periodic task.
- (void)stop;

/// Perform one probe-and-repair cycle synchronously. Returns YES if write
/// access is present after the call. Exposed for a manual "check now" action.
- (BOOL)tick;

/// Does the process currently have write access to a privileged path?
/// Read-only check; performs no kernel writes.
+ (BOOL)hasPrivilegedWriteAccess;

/// Probe, and if write access is gone, re-apply the sandbox policy once.
/// Synchronous. Returns YES when write access is present afterwards.
///
/// This is what a failed file operation calls before giving up: the sandbox
/// policy edit is volatile, so an unlink() that worked a minute ago can start
/// failing with EPERM while nothing about the file itself changed.
+ (BOOL)ensureWriteAccess;

/// 手动「修复写权限」：探针 → 丢了就用现成的内核原语重放沙箱逃逸 → 再探一次。
/// path 非空时额外把该路径所属容器的属主修成 mobile（DAC 那一层），
/// 也就是 blade 的「修复写权限」按钮做的事情。
///
/// 返回一段可以直接显示给用户的报告（多行，中文）。同步执行，会写内核，
/// 调用方必须自己放到后台队列、不要在 main thread 上调用。
+ (NSString *)repairWriteAccessReportForPath:(NSString *)path;

/// 探针一失败就立刻重放逃逸，并把「是谁之后掉的」记进日志。
///
/// 为什么要单独一个方法：**文件写/删本身就会把逃逸冲掉**。
/// 逃逸的做法是把一条按路径签发的 extension 改成「全局可读写 + 指向 /」，
/// 而这个改动只活在内存里；任何一次真实的文件操作都会让内核重新处理扩展表，
/// 我们改进去的那份就被换回原样 —— 于是"写/删一个文件后权限必掉"。
/// 所以每个会落盘的操作结束后都要过一遍这里。
///
/// 探针成功时（4 个 syscall）直接返回，**一个字节的内核写都不会发生**；
/// 只有确认丢了才重放，和手动修复走的是同一条路径。
+ (BOOL)restoreIfLost:(NSString *)reason;

/// 探针发现丢失时是否自动重放逃逸。默认 YES。
/// 关掉后 keeper 只观察不写内核（旧行为）。
@property (nonatomic, assign) BOOL autoRepair;

@end

NS_ASSUME_NONNULL_END
