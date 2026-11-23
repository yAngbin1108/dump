//
//  SKKernelcache.h
//  Blade
//
//  Download the running device's kernelcache.
//
//  WHY THIS EXISTS
//  ---------------
//  libgrabkernel2 does the same job, but it cannot do it for a current device.
//  What an IPSW actually contains:
//
//      kernelcache.release.<board>   deflate, ~18 MB
//        -> inflates to a DER-encoded IMG4
//             SEQUENCE
//               IA5String "IM4P"
//               IA5String "krnl"
//               IA5String "KernelManagement_host-..."
//               OCTET STRING   <-- the payload
//        -> and the payload's first four bytes are "bvx2": LZFSE.
//
//  The real hazard is earlier: every modern IPSW is over 4 GB, so the archive is
//  ZIP64 and each central-directory entry stores 0xFFFFFFFF for its local-header
//  offset, with the real value in the ZIP64 extra field. A reader that ignores
//  that field seeks to a nonsense offset and reports "Local file header
//  signature is invalid".
//
//  Note that the LZFSE payload is NOT this code's problem, and decoding it would
//  be a mistake: the DER/IMG4 is the artifact. iskcachevalid() in offsets.m
//  accepts a file starting 0x30 0x84, and libxpf parses the IMG4 directly. So
//  the pipeline stops at deflate — ZIP64-aware central directory, inflate, and
//  a 30 84 sanity check. See SKKernelcache.m for the reasoning.
//

#ifndef SKKernelcache_h
#define SKKernelcache_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Fetch the kernelcache for the firmware at `firmwareURL` (an IPSW URL) and
/// write the DER-encoded IMG4 kernelcache to `outPath` — not a raw Mach-O.
/// The IMG4 is what iskcachevalid() accepts and what libxpf parses.
///
/// Returns nil on success, otherwise a short reason suitable for a log line.
/// Blocking; call it off the main thread.
NSString *_Nullable SKKernelcacheFetch(NSString *outPath, NSString *firmwareURL);

/// As above, but told explicitly which product type to select the kernelcache
/// for. Pass the value of hw.machine. An IPSW may carry several
/// kernelcache.release.* entries and they are board-specific, so the product
/// type is what makes the choice exact instead of a guess.
NSString *_Nullable SKKernelcacheFetchForProduct(NSString *outPath,
                                                 NSString *firmwareURL,
                                                 NSString *_Nullable productType);

NS_ASSUME_NONNULL_END

#endif /* SKKernelcache_h */
