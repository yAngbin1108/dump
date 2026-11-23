//
//  SKFileWriter.h
//  SandboxKit — write files that Unix permissions would otherwise refuse
//
//  The sandbox escape removes the *sandbox* restriction, but it does not change
//  Unix ownership or mode bits. Writing deep inside another app's bundle can
//  therefore still fail with EACCES: the process has sandbox permission to reach
//  the path, but not filesystem permission to modify the inode.
//
//  The exploit chain ships a kernel-assisted path for exactly this:
//  vfs_overwritebytes() mmaps the target read-only, then patches the mapping's
//  vm_map_entry protection bits through the kernel R/W primitive and writes
//  through the now-writable mapping. That bypasses the Unix write check without
//  touching on-disk permissions.
//
//  This class tries the ordinary write first (fast, no kernel involvement) and
//  falls back to the kernel path only when the ordinary one is refused.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SKWriteMethod) {
    SKWriteMethodNormal = 0,
    SKWriteMethodKernel,      // had to bypass Unix permissions
    SKWriteMethodFailed,
};

@interface SKFileWriter : NSObject

/// Overwrite `length` bytes at `offset` inside `path`.
/// Returns the method that succeeded, or SKWriteMethodFailed.
+ (SKWriteMethod)writeToPath:(NSString *)path
                      offset:(off_t)offset
                        data:(NSData *)data
                       error:(NSError **)error;

/// Replace the whole content of `path`. The replacement must not be larger than
/// the existing file, because the kernel-assisted path cannot grow a file.
+ (SKWriteMethod)replacePath:(NSString *)path
                    withData:(NSData *)data
                       error:(NSError **)error;

/// Whether the kernel-assisted path is usable right now (primitive is up).
+ (BOOL)kernelWriteAvailable;

/// Human-readable label for a method, for logs.
+ (NSString *)describeMethod:(SKWriteMethod)m;

@end

NS_ASSUME_NONNULL_END
