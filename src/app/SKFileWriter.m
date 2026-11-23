//
//  SKFileWriter.m
//  SandboxKit — write files that Unix permissions would otherwise refuse
//
//  See SKFileWriter.h.
//

#import "SKLoc.h"
#import "SKFileWriter.h"
#import "darksword.h"
#import "vfs.h"

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

@implementation SKFileWriter

+ (BOOL)kernelWriteAvailable {
    return ds_is_ready() && vfs_isready();
}

+ (NSString *)describeMethod:(SKWriteMethod)m {
    switch (m) {
        case SKWriteMethodNormal: return SKLoc(@"fw.mode.normal");
        case SKWriteMethodKernel: return SKLoc(@"fw.mode.kernel");
        default:                  return @"failed";
    }
}

static NSError *skerr(NSString *msg) {
    return [NSError errorWithDomain:@"SKFileWriter"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// ─────────────────────────────────────────────────────────────────────────────
// Ordinary write. Returns YES on success. Any failure falls through to the
// kernel path, including EACCES and EPERM.
// ─────────────────────────────────────────────────────────────────────────────
static BOOL normalWrite(NSString *path, off_t offset, NSData *data) {
    int fd = open(path.UTF8String, O_WRONLY);
    if (fd < 0) return NO;

    // Keep the file size unchanged: the kernel path cannot grow a file, so the
    // two paths must agree on what "success" means.
    off_t size = lseek(fd, 0, SEEK_END);
    if (size < offset + (off_t)data.length) { close(fd); return NO; }

    ssize_t n = pwrite(fd, data.bytes, data.length, offset);
    int saved = errno;
    close(fd);
    if (n != (ssize_t)data.length) { errno = saved; return NO; }
    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
+ (SKWriteMethod)writeToPath:(NSString *)path
                      offset:(off_t)offset
                        data:(NSData *)data
                       error:(NSError **)error {
    if (!path.length || !data.length) {
        if (error) *error = skerr(SKLoc(@"fw.err.noPath"));
        return SKWriteMethodFailed;
    }

    if (normalWrite(path, offset, data)) {
        return SKWriteMethodNormal;
    }

    int normalErrno = errno;

    if (![self kernelWriteAvailable]) {
        if (error) {
            *error = skerr([NSString stringWithFormat:SKLoc(@"fw.err.denied"),
                            normalErrno, strerror(normalErrno)]);
        }
        return SKWriteMethodFailed;
    }

    // Kernel-assisted path: mmap read-only, repatch the mapping's protection,
    // write through it. vfs_overwritebytes() does all of that.
    int rc = vfs_overwritebytes(path.UTF8String, offset, data.bytes, data.length);
    if (rc == 0) {
        return SKWriteMethodKernel;
    }

    if (error) {
        *error = skerr([NSString stringWithFormat:SKLoc(@"fw.err.bothFailed"),
                        normalErrno, strerror(normalErrno), rc]);
    }
    return SKWriteMethodFailed;
}

// ─────────────────────────────────────────────────────────────────────────────
+ (SKWriteMethod)replacePath:(NSString *)path
                    withData:(NSData *)data
                       error:(NSError **)error {
    return [self writeToPath:path offset:0 data:data error:error];
}

@end
