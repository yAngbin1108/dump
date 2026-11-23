//
//  SKAppOwn.m
//  Blade
//

#import "SKAppOwn.h"
#import "SKLog.h"
#import "SKKernelLock.h"
#import "darksword.h"
#import "apfs.h"

#include <string.h>
#include <sys/stat.h>

static NSString * const kBundlePrefix = @"/var/containers/Bundle/Application/";
static NSString * const kDataPrefix   = @"/var/containers/Data/Application/";

// mobile:mobile — the uid this process runs as. Once the container's fsnode
// carries this owner the ordinary write()/rename()/unlink() calls work.
static const uid_t kTargetUID = 501;
static const gid_t kTargetGID = 501;

// Belt and braces against pathological trees.
static const NSUInteger kMaxEntries = 200000;
static const int kMaxDepth = 48;

NSString *SKOwnershipRootForPath(NSString *path) {
    if (!path.length) return nil;
    NSArray<NSString *> *comps = path.pathComponents;

    // Bundle: stop at the .app component.
    if ([path hasPrefix:kBundlePrefix]) {
        for (NSUInteger i = 0; i < comps.count; i++) {
            if ([comps[i] hasSuffix:@".app"]) {
                return [NSString pathWithComponents:[comps subarrayWithRange:NSMakeRange(0, i + 1)]];
            }
        }
        return nil;
    }

    // Data container: the first component after the prefix is the UUID.
    if ([path hasPrefix:kDataPrefix]) {
        // "/" + var + containers + Data + Application + <UUID>  == 6 components
        if (comps.count >= 6) {
            return [NSString pathWithComponents:[comps subarrayWithRange:NSMakeRange(0, 6)]];
        }
        return nil;
    }

    return nil;
}

// _CodeSignature holds the bundle's signature; SC_Info holds FairPlay data.
// Rewriting their owner is pointless and touching their content would break
// signing — so they are skipped entirely.
static BOOL SKShouldSkip(const char *name) {
    return strcmp(name, "_CodeSignature") == 0 ||
           strcmp(name, "SC_Info") == 0;
}

static NSUInteger SKOwnTreeAt(NSString *path, int depth) {
    if (depth > kMaxDepth) return 0;

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;

    // Serialise with every other kernel user. SKSandboxKeeper re-applies
    // sbx_escape() on a timer and the memory editor writes kernel memory too.
    [SKKernelLock() lock];
    BOOL alreadyOurs = NO;
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0 && st.st_uid == kTargetUID) {
        alreadyOurs = YES;
    }
    int rc = alreadyOurs ? 0 : apfs_own(path.fileSystemRepresentation, kTargetUID, kTargetGID);
    [SKKernelLock() unlock];

    if (rc != 0) {
        SKLog(@"apfsown: FAILED %@", path);
        return 0;
    }

    NSUInteger n = 1;
    if (!isDir) return n;

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:path error:NULL];
    for (NSString *e in entries) {
        if (SKShouldSkip(e.fileSystemRepresentation)) continue;
        n += SKOwnTreeAt([path stringByAppendingPathComponent:e], depth + 1);
        if (n > kMaxEntries) {
            SKLog(@"apfsown: stopped at %lu entries (cap)", (unsigned long)kMaxEntries);
            break;
        }
    }
    return n;
}

BOOL SKOwnTree(NSString *root) {
    if (!root.length) return NO;
    if (!ds_is_ready()) return NO;

    NSUInteger n = SKOwnTreeAt(root, 0);
    SKLog(@"apfsown: %@ — %lu entries now %d:%d", root, (unsigned long)n, kTargetUID, kTargetGID);
    return n > 0;
}

BOOL SKEnsureWriteAccess(NSString *path) {
    NSString *root = SKOwnershipRootForPath(path);
    if (!root) return YES;                   // not a container path; DAC is not our problem
    if (!ds_is_ready()) return NO;

    // What governs create/delete/rename is the PARENT DIRECTORY's ownership, not
    // the target's. Checking `path` itself was the bug: deleting a file we had
    // just created (already uid 501) returned YES immediately and skipped the
    // whole tree fix, so unlink() failed with EACCES because the containing
    // .app directory still was not ours.
    NSString *dir = [path stringByDeletingLastPathComponent];
    struct stat st;
    if (dir.length &&
        stat(dir.fileSystemRepresentation, &st) == 0 &&
        st.st_uid == kTargetUID) {
        return YES;                          // parent is ours — cheap common case
    }

    SKLog(@"apfsown: write needs ownership fix, parent=%@", dir);
    return SKOwnTree(root);
}

void SKOwnershipFixAsync(NSString *path) {
    NSString *root = SKOwnershipRootForPath(path);
    if (!root.length) return;
    if (!ds_is_ready()) return;              // needs the kernel primitive

    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        if ([seen containsObject:root]) return;   // once per container per launch
        [seen addObject:root];
    }

    SKLog(@"apfsown: queued %@", root);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SKOwnTree(root);
    });
}
