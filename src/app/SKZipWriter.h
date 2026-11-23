//
//  SKZipWriter.h
//  Blade — streaming ZIP writer
//
//  The file manager's zipPathTo() loads every file into memory before writing
//  anything. Packaging an .ipa means zipping a whole app bundle (hundreds of
//  megabytes), so that approach exhausts memory and the process is killed
//  before the archive is ever written — leaving a zero-byte .ipa behind.
//
//  This writer streams: each file is checksummed, its local header written and
//  its bytes copied straight through in fixed-size chunks, so peak memory is
//  one chunk regardless of how large the input is.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SKZipWriter : NSObject

/// Recursively archive `srcDir` into `dstPath`. Entries are prefixed with the
/// directory's own name, so zipping `<x>/Payload` yields `Payload/...`.
///
/// Returns nil on success, or a human-readable reason on failure.
+ (nullable NSString *)zipDirectory:(NSString *)srcDir
                             toPath:(NSString *)dstPath
                       progress:(void (^ _Nullable)(NSString *entry, NSUInteger done, NSUInteger total))progress;

@end

NS_ASSUME_NONNULL_END
