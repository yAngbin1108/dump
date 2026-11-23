//
//  SKKernelLock.m
//  Blade — the single process-wide kernel primitive lock
//
//  Defined here, in exactly one translation unit. See the header for why this
//  cannot be a `static inline` in the header.
//

#import "SKKernelLock.h"

NSLock *SKKernelLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
        lock.name = @"blade.kernel";
    });
    return lock;
}
