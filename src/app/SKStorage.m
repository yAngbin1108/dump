//
//  SKStorage.m
//  Blade
//

#import "SKStorage.h"
#import "SKLog.h"

#include <sys/stat.h>
#include <unistd.h>

// 日志留这么大就够了，超了从头写。
static const unsigned long long kSKLogMaxBytes = 1024 * 1024;      // 1 MB
// 内核缓存是几百 MB 的那个，单独留着（重新下载要几分钟）。
static NSString * const kKernelcacheName = @"kernelcache";

static NSString *sk_docs(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                               NSUserDomainMask, YES).firstObject;
}

unsigned long long SKStorageDirectorySize(NSString *path) {
    if (!path.length) return 0;

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;

    if (!isDir) {
        NSDictionary *a = [fm attributesOfItemAtPath:path error:NULL];
        return [[a objectForKey:NSFileSize] unsignedLongLongValue];
    }

    unsigned long long total = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:path];
    for (NSString *rel in en) {
        NSString *full = [path stringByAppendingPathComponent:rel];
        BOOL d = NO;
        if (![fm fileExistsAtPath:full isDirectory:&d] || d) continue;
        NSDictionary *a = [fm attributesOfItemAtPath:full error:NULL];
        total += [[a objectForKey:NSFileSize] unsignedLongLongValue];
    }
    return total;
}

// 砸壳的工作目录都是 Documents/Decrypted/.tmp_*。启动时不可能有正在进行的
// 砸壳，所以看到就删，不用管新旧。
unsigned long long SKStorageRemoveDecryptWorkDirs(void) {
    NSString *docs = sk_docs();
    if (!docs.length) return 0;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *outDir = [docs stringByAppendingPathComponent:@"Decrypted"];

    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:outDir error:NULL];
    unsigned long long freed = 0;
    int removed = 0;

    for (NSString *name in items) {
        // .tmp_<bundleID>；以前还有过 .tmp.<random> 这种，一并清掉
        if (![name hasPrefix:@".tmp"]) continue;
        NSString *full = [outDir stringByAppendingPathComponent:name];
        freed += SKStorageDirectorySize(full);
        if ([fm removeItemAtPath:full error:NULL]) removed++;
    }

    if (removed > 0) {
        SKLog(@"[storage] 清掉 %d 个砸壳残留目录，释放 %.1f MB",
              removed, freed / 1048576.0);
    }
    return freed;
}

// 日志太大就从头写。日志只用于事后排查，丢掉旧的部分没有损失。
static void sk_truncate_if_big(NSString *path) {
    if (!path.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *a = [fm attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [[a objectForKey:NSFileSize] unsignedLongLongValue];
    if (size <= kSKLogMaxBytes) return;

    // 不是 unlink 再建：保持文件本身的属主和权限不变。
    FILE *f = fopen(path.fileSystemRepresentation, "r+");
    if (!f) return;
    if (ftruncate(fileno(f), 0) == 0) {
        fclose(f);
        SKLog(@"[storage] 日志 %@ 超过 %.1f MB，已截断",
              path.lastPathComponent, kSKLogMaxBytes / 1048576.0);
    } else {
        fclose(f);
    }
}

void SKStorageSweepOnLaunch(void) {
    @autoreleasepool {
        NSString *docs = sk_docs();
        if (!docs.length) return;

        SKStorageRemoveDecryptWorkDirs();

        // utils_log_file() 写的那个（内核读写的逐条诊断），它自己不设上限。
        // 链代码保持 blade 原样，文件名是 lara.log；同时把老版本留下的
        // kernel.log 一起收掉。
        sk_truncate_if_big([docs stringByAppendingPathComponent:@"lara.log"]);
        sk_truncate_if_big([docs stringByAppendingPathComponent:@"kernel.log"]);

        // 往日志里报一下自己在 Documents 下占了多少，方便一眼看出有没有异常增长
        unsigned long long own = SKStorageOwnFootprint();
        if (own > 0) {
            SKLog(@"[storage] Blade 在 Documents 下共占用 %.1f MB", own / 1048576.0);
        }
    }
}

unsigned long long SKStorageOwnFootprint(void) {
    NSString *docs = sk_docs();
    if (!docs.length) return 0;

    unsigned long long total = 0;
    total += SKStorageDirectorySize([docs stringByAppendingPathComponent:@"Decrypted"]);
    total += SKStorageDirectorySize([docs stringByAppendingPathComponent:@"sk.log"]);
    total += SKStorageDirectorySize([docs stringByAppendingPathComponent:@"lara.log"]);
    total += SKStorageDirectorySize([docs stringByAppendingPathComponent:@"kernel.log"]);
    total += SKStorageDirectorySize([docs stringByAppendingPathComponent:kKernelcacheName]);
    return total;
}
