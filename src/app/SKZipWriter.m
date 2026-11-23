//
//  SKZipWriter.m
//  Blade — streaming ZIP writer
//
//  STORE-only archive (method 0), which sidesteps memory entirely: each file
//  is checksummed and copied in fixed-size chunks and never fully resident.
//  See SKZipWriter.h for why the old in-memory approach failed.
//

#import "SKLoc.h"
#import "SKZipWriter.h"
#include <sys/stat.h>
#include <sys/attr.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - CRC32
// ─────────────────────────────────────────────────────────────────────────────
static uint32_t crcTable[256];
static dispatch_once_t crcOnce;

static void crcInit(void) {
    dispatch_once(&crcOnce, ^{
        for (uint32_t n = 0; n < 256; n++) {
            uint32_t c = n;
            for (int k = 0; k < 8; k++) {
                c = (c & 1) ? (0xedb88320U ^ (c >> 1)) : (c >> 1);
            }
            crcTable[n] = c;
        }
    });
}

static uint32_t crcUpdate(uint32_t crc, const uint8_t *p, size_t n) {
    crcInit();
    for (size_t i = 0; i < n; i++) {
        crc = crcTable[(crc ^ p[i]) & 0xff] ^ (crc >> 8);
    }
    return crc;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - LE helpers
// ─────────────────────────────────────────────────────────────────────────────
static void leAppend16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff) };
    [d appendBytes:b length:2];
}
static void leAppend32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff),
                     (uint8_t)((v >> 16) & 0xff), (uint8_t)((v >> 24) & 0xff) };
    [d appendBytes:b length:4];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Entry model
// ─────────────────────────────────────────────────────────────────────────────
@interface SKZipEntry : NSObject
@property (nonatomic, copy) NSString *srcPath;   // absolute path on disk
@property (nonatomic, copy) NSString *zipName;   // name inside the archive
@property (nonatomic, assign) mode_t mode;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, assign) uint32_t crc;
@property (nonatomic, assign) uint32_t offset;
@end
@implementation SKZipEntry
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Writer
// ─────────────────────────────────────────────────────────────────────────────
@implementation SKZipWriter

+ (NSString *)zipDirectory:(NSString *)srcDir
                    toPath:(NSString *)dstPath
                  progress:(void (^)(NSString *, NSUInteger, NSUInteger))progress {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:srcDir isDirectory:&isDir] || !isDir) {
        return SKLoc(@"zip.err.srcMissing");
    }

    // ── 1. enumerate everything first (metadata only, no file data) ────────
    NSString *root = srcDir.lastPathComponent;
    NSMutableArray<SKZipEntry *> *entries = [NSMutableArray array];

    NSDirectoryEnumerator *en = [fm enumeratorAtPath:srcDir];
    for (NSString *rel in en) {
        @autoreleasepool {
            NSString *full = [srcDir stringByAppendingPathComponent:rel];
            struct stat st;
            if (lstat(full.fileSystemRepresentation, &st) != 0) continue;

            SKZipEntry *e = [SKZipEntry new];
            e.srcPath = full;
            e.mode = st.st_mode;
            e.isDir = S_ISDIR(st.st_mode);
            e.zipName = e.isDir ? [rel stringByAppendingString:@"/"] : rel;

            if (S_ISREG(st.st_mode)) {
                e.size = (uint64_t)st.st_size;
                [entries addObject:e];
            } else if (S_ISDIR(st.st_mode)) {
                [entries addObject:e];
            }
            // Symlinks, sockets, devices: skipped — they don't belong in an ipa.
        }
    }
    if (entries.count == 0) {
        return SKLoc(@"zip.err.empty");
    }

    // ── 2. disk-space sanity check ──────────────────────────────────────────
    {
        NSDictionary *attrs = [fm attributesOfFileSystemForPath:srcDir error:NULL];
        if (attrs) {
            unsigned long long freeBytes = [attrs[NSFileSystemFreeSize] unsignedLongLongValue];
            uint64_t total = 0;
            for (SKZipEntry *e in entries) total += e.size;
            if (freeBytes < total + (1ULL << 22)) {
                return [NSString stringWithFormat:SKLoc(@"zip.err.noSpace"),
                        total / 1048576.0, freeBytes / 1048576.0];
            }
        }
    }

    // ── 3. stream every entry ───────────────────────────────────────────────
    [fm createFileAtPath:dstPath contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:dstPath];
    if (!out) return SKLoc(@"zip.err.createOut");

    NSMutableData *cdEntries = [NSMutableData data];
    uint16_t totalCount = 0;

    NSUInteger done = 0;
    for (SKZipEntry *e in entries) {
        @autoreleasepool {
            // Path prefix is relative to srcDir's parent so the archive root is
            // the folder itself: Payload/... etc.
            NSString *fullName = [root stringByAppendingPathComponent:e.zipName];
            if (e.isDir) fullName = [fullName stringByAppendingString:@"/"];
            NSData *nameData = [fullName dataUsingEncoding:NSUTF8StringEncoding];
            if (!nameData) { [out closeFile]; return SKLoc(@"zip.err.encodeName"); }
            uint16_t nameLen = (uint16_t)nameData.length;

            uint32_t crc = 0;
            uint64_t size = 0;
            NSFileHandle *in = nil;

            if (!e.isDir) {
                in = [NSFileHandle fileHandleForReadingAtPath:e.srcPath];
                if (!in) { [out closeFile]; return SKLoc(@"zip.err.readInput"); }

                // Pass 1: checksum.
                uint32_t running = 0xffffffffU;
                while (YES) {
                    NSData *chunk = [in readDataOfLength:(1u << 20)];
                    if (chunk.length == 0) break;
                    running = crcUpdate(running, chunk.bytes, chunk.length);
                    size += chunk.length;
                }
                crc = running ^ 0xffffffffU;
                [in seekToFileOffset:0];

                if (size > 0xFFFFFFFEULL) { [in closeFile]; [out closeFile]; return SKLoc(@"zip.err.tooBig"); }
            }

            uint32_t offset = (uint32_t)out.offsetInFile;

            // Local file header.
            NSMutableData *lfh = [NSMutableData data];
            leAppend32(lfh, 0x04034b50);
            leAppend16(lfh, 20);                 // version needed
            leAppend16(lfh, 0x0800);             // UTF-8 names
            leAppend16(lfh, 0);                  // method: store
            leAppend16(lfh, 0);                  // mod time
            leAppend16(lfh, 0);                  // mod date
            leAppend32(lfh, crc);
            leAppend32(lfh, (uint32_t)size);
            leAppend32(lfh, (uint32_t)size);
            leAppend16(lfh, nameLen);
            leAppend16(lfh, 0);                  // extra
            [out writeData:lfh];
            [out writeData:nameData];

            // Stream the payload.
            if (!e.isDir) {
                while (YES) {
                    NSData *chunk = [in readDataOfLength:(1u << 20)];
                    if (chunk.length == 0) break;
                    [out writeData:chunk];
                }
                [in closeFile];
            }

            // Central directory entry.
            uint32_t extAttr = (uint32_t)(e.isDir ? (e.mode | S_IFDIR) : (e.mode | S_IFREG));
            NSMutableData *cd = [NSMutableData data];
            leAppend32(cd, 0x02014b50);
            // The HIGH byte of "version made by" is the host system: 0 = FAT,
            // 3 = Unix. With 0 the reader ignores the Unix mode in the external
            // attributes and invents 0644 — which silently strips the executable
            // bit off every binary and breaks the installed app.
            leAppend16(cd, (3 << 8) | 20);       // version made by: Unix, 2.0
            leAppend16(cd, 20);                  // version needed
            leAppend16(cd, 0x0800);              // UTF-8
            leAppend16(cd, 0);                   // method: store
            leAppend16(cd, 0);                   // mod time
            leAppend16(cd, 0);                   // mod date
            leAppend32(cd, crc);
            leAppend32(cd, (uint32_t)size);
            leAppend32(cd, (uint32_t)size);
            leAppend16(cd, nameLen);
            leAppend16(cd, 0);                   // extra
            leAppend16(cd, 0);                   // comment
            leAppend16(cd, 0);                   // disk
            leAppend16(cd, 0);                   // internal attr
            leAppend32(cd, extAttr << 16);       // Unix mode in the HIGH half
            leAppend32(cd, offset);
            [cd appendData:nameData];
            [cdEntries appendData:cd];

            totalCount++;
            done++;
            if (progress) progress(fullName, done, entries.count);
        }
    }

    // ── 4. central directory + EOCD ────────────────────────────────────────
    uint32_t cdOffset = (uint32_t)out.offsetInFile;
    [out writeData:cdEntries];
    uint32_t cdSize = (uint32_t)cdEntries.length;

    NSMutableData *eocd = [NSMutableData data];
    leAppend32(eocd, 0x06054b50);
    leAppend16(eocd, 0);                     // disk
    leAppend16(eocd, 0);                     // cd disk
    leAppend16(eocd, totalCount);            // entries on disk
    leAppend16(eocd, totalCount);            // total entries
    leAppend32(eocd, cdSize);
    leAppend32(eocd, cdOffset);
    leAppend16(eocd, 0);                     // comment length
    [out writeData:eocd];
    [out synchronizeFile];
    [out closeFile];

    // ── 5. verify the archive we just wrote ────────────────────────────────
    {
        NSDictionary *attrs = [fm attributesOfItemAtPath:dstPath error:NULL];
        unsigned long long finalSize = [attrs[NSFileSize] unsignedLongLongValue];
        if (finalSize == 0 || finalSize < (unsigned long long)cdEntries.length + 22) {
            return SKLoc(@"zip.err.verify");
        }
    }

    return nil;
}

@end
