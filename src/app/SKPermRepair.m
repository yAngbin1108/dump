//
//  SKPermRepair.m
//  AppDump
//
//  实现全部来自 blade：app/../FileManager.m 里的 SKKernelTakeOwnership /
//  SKKernelOwnParent / SKEnsureAppChowned 三个函数，逻辑一字未改，只把名字
//  统一成 SKPermission*，并去掉与本文件无关的部分。
//

#import "SKPermRepair.h"
#import "SKLog.h"
#import "SKKernelLock.h"
#import "SKPathPolicy.h"

#import "apfs.h"
#import "darksword.h"

#include <sys/stat.h>
#include <unistd.h>

#pragma mark - 单路径修复（blade: SKKernelTakeOwnership）

BOOL SKPermissionRepair(NSString *path) {
    if (path.length == 0) return NO;
    if (!ds_is_ready()) return NO;
    // 收口：所有"内核改属主"都必须过这条，否则从 /Applications 下的
    // plist/文本编辑器点保存就能把系统文件 chown 成 mobile。
    if (!SKPathAllowsModify(path)) return NO;

    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (stat(p, &st) != 0) return NO;

    // 已经是我们、且 owner 可写 —— 什么都不用做（整树 chown 之后是常态，
    // 于是这里零内核写）。
    if (st.st_uid == 501 && (st.st_mode & S_IWUSR)) return YES;

    // apfs_* 内部不加锁（NSLock 非递归），约定调用方持锁。
    // 整段包 @try：ds_kwrite* 走 set_target_kaddr，地址不合规会抛 NSException，
    // 不接住就是闪退；@finally 保证锁一定释放，否则后面所有内核操作卡死。
    BOOL ok = NO;
    [SKKernelLock() lock];
    @try {
        apfs_own(p, 501, 501);
        // 必须带类型位，否则会把 S_IFDIR/S_IFREG 清零
        apfs_mod(p, (mode_t)((st.st_mode & 0xFFFF) | S_IRUSR | S_IWUSR));
        struct stat after;
        ok = (stat(p, &after) == 0) && after.st_uid == 501;
    } @catch (NSException *ex) {
        SKLog(@"[perm] kernel repair threw for %@: %@", path, ex.reason);
        ok = NO;
    } @finally {
        [SKKernelLock() unlock];
    }

    SKLog(@"[perm] repair %@: %@ (uid %u->501 mode %04o->%04o)", path,
          ok ? @"ok" : @"failed", (unsigned)st.st_uid, st.st_mode & 07777,
          (st.st_mode & 07777) | 0600);
    return ok;
}

BOOL SKPermissionRepairParent(NSString *path) {
    NSString *parent = path.stringByDeletingLastPathComponent;
    if (parent.length == 0) return NO;
    return SKPermissionRepair(parent);
}

#pragma mark - 进入目录整树 chown（blade: SKEnsureAppChowned）

// Filza 能往 .app 里写，不是"绕过写检查"，而是先把整棵 bundle 的属主改成
// mobile —— 之后建文件 / 改名 / 粘贴全部走普通系统调用。
// 触发时机照抄 Filza：每次列目录时，如果这个路径落在某个 .app 里，就把那个
// .app 作为一个整体在后台 chown 一次（每个 bundle 一次）。
// apfs_own_tree 内部会跳过 _CodeSignature / SC_Info —— 改那两个会破坏代码签名。

static NSMutableSet<NSString *> *gChownedApps = nil;
static dispatch_queue_t gChownQueue = NULL;

static NSString *SKAppRootForPath(NSString *path) {
    if (![path hasPrefix:@"/var/containers/Bundle/Application/"] &&
        ![path hasPrefix:@"/private/var/containers/Bundle/Application/"]) return nil;
    NSArray<NSString *> *comps = path.pathComponents;
    for (NSUInteger i = 0; i < comps.count; i++) {
        if ([comps[i] hasSuffix:@".app"]) {
            return [NSString pathWithComponents:[comps subarrayWithRange:NSMakeRange(0, i + 1)]];
        }
    }
    return nil;
}

void SKPermissionRepairForDirectory(NSString *dirPath) {
    NSString *appRoot = SKAppRootForPath(dirPath);
    if (!appRoot) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gChownedApps = [NSMutableSet new];
        gChownQueue = dispatch_queue_create("appdump.autochown", DISPATCH_QUEUE_SERIAL);
    });

    @synchronized (gChownedApps) {
        if ([gChownedApps containsObject:appRoot]) return;
        [gChownedApps addObject:appRoot];    // 先标记，避免并发重复跑
    }

    if (!SKPathAllowsModify(appRoot)) return;   // 系统目录永不动

    dispatch_async(gChownQueue, ^{
        if (!ds_is_ready()) return;
        SKLog(@"[perm] entering .app, whole-tree chown: %@", appRoot);

        // 整棵树是一次内核操作：必须全程持锁，否则会和 sbx_escape / vfs /
        // 扫描同时动内核原语 —— 那会直接 panic。
        long n = 0;
        [SKKernelLock() lock];
        @try {
            n = apfs_own_tree(appRoot.fileSystemRepresentation, 501, 501);
        } @catch (NSException *ex) {
            SKLog(@"[perm] tree chown threw for %@: %@", appRoot, ex.reason);
        } @finally {
            [SKKernelLock() unlock];
        }
        SKLog(@"[perm] %@ done: %ld entries set to mobile", appRoot, n);
        // 一项都没改成说明这次没生效（原语可能还没就绪）。撤销标记，
        // 下次进这个 .app 还会再试。
        if (n <= 0) {
            @synchronized (gChownedApps) { [gChownedApps removeObject:appRoot]; }
            SKLog(@"[perm] %@ tree chown had no effect, marker removed for retry", appRoot);
        }
    });
}

BOOL SKPermissionHasRepairedAppTree(NSString *appRoot) {
    if (!gChownedApps || !appRoot) return NO;
    @synchronized (gChownedApps) { return [gChownedApps containsObject:appRoot]; }
}
