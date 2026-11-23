//
//  SKAppOwn.h
//  Blade
//
//  Write access inside app containers (bundle and data).
//
//  PROBLEM
//  -------
//  The sandbox escape only removes the MAC (sandbox) gate. Files under
//  /var/containers/... are also subject to the ordinary UNIX owner/mode check,
//  and inside an .app bundle they are not owned by the uid this process runs as,
//  so open(O_WRONLY) still fails with EACCES even with a full read-write sandbox
//  extension.
//
//  HOW THIS IS SOLVED
//  ------------------
//  The same way FilzaJailedDS (34306/FilzaJailedDS, release 2.1) does it: walk
//  vnode -> v_data -> apfs_fsnode and rewrite uid/gid to 501:501 (mobile)
//  directly in the kernel. apfs_fsnode lives in an ordinary writable zone, so
//  the kernel write primitive can reach it — unlike proc_ro/ucred, which are
//  page-table protected and simply cannot be written, however the exploit is
//  arranged.
//
//  Both the browse path and the write path call into here: browsing warms the
//  fix up in the background, and every write calls SKEnsureWriteAccess() first so
//  the very first write cannot race the background pass.
//
//  IMPORTANT LIMIT (not fixable here)
//  ----------------------------------
//  This makes the FILES writable. It does not make a modified binary loadable:
//  editing an executable inside .app invalidates its signature and AMFI refuses
//  it. Safe for data files, resources, plists; do not expect a patched Mach-O to
//  launch.
//

#ifndef SKAppOwn_h
#define SKAppOwn_h

#import <Foundation/Foundation.h>

/// The container root whose ownership governs `path`, or nil when `path` is not
/// inside a container. Covers:
///   /var/containers/Bundle/Application/<UUID>/Foo.app[/...]  -> the .app root
///   /var/containers/Data/Application/<UUID>[/...]            -> the data container
NSString *SKOwnershipRootForPath(NSString *path);

/// Recursively chown `root` to 501:501 through apfs_fsnode. Synchronous, so call
/// it off the main thread. Skips _CodeSignature and SC_Info, whose contents must
/// stay untouched for the signature (and FairPlay) to remain valid.
BOOL SKOwnTree(NSString *root);

/// Make `path` writable by us, synchronously, before a write is attempted.
/// Returns YES when the caller may proceed (ownership already ours, or fixed, or
/// the path is not a container path at all). This is what stops the first write
/// after navigating into a bundle from racing the background pass.
BOOL SKEnsureWriteAccess(NSString *path);

/// Background ownership fix for the container holding `path`. No-op unless the
/// kernel primitive is up and the path is inside a container. Each root is only
/// processed once per launch.
void SKOwnershipFixAsync(NSString *path);

#endif /* SKAppOwn_h */
