//
//  SKKernelLock.h
//  Blade — serialise access to the kernel primitives
//
//  The exploit's read/write helpers and kexploit's vm layer are NOT thread
//  safe: vmmapremotepage() allocates a memory entry, repurposes a vm_map entry
//  and bumps the target vm_object's refcount through the kernel, and the
//  kread/kwrite primitives share per-process state. Two threads doing that at
//  once corrupts that state — which surfaces as a kernel panic.
//
//  Anything in this app that touches the primitive must hold this lock for the
//  duration of the operation.
//
//  CONTRACT: the lock is taken by the CALLER. apfs_own() / apfs_mod() /
//  apfs_own_tree() in kexploit/pe must be called with it already held — they do
//  not lock internally, because SKAppOwn does `lock -> apfs_own -> unlock` and
//  NSLock is not recursive.
//

#ifndef SK_KERNEL_LOCK_H
#define SK_KERNEL_LOCK_H

#import <Foundation/Foundation.h>

/// Process-wide lock guarding the kernel R/W primitives.
///
/// MUST be a real singleton, so the definition lives in SKKernelLock.m — NOT a
/// `static inline` in this header.
///
/// An earlier revision had it inline here, which gives every translation unit
/// its own copy of the function *and* its own `static NSLock`. Five files called
/// SKKernelLock(), each got a different lock, and nothing was ever serialised —
/// exactly the concurrent-primitive corruption this exists to prevent.
NSLock *SKKernelLock(void);

#endif
