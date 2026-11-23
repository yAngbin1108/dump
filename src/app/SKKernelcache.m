//
//  SKKernelcache.m
//  Blade
//

#import "SKKernelcache.h"

#import "SKLog.h"

#include <zlib.h>
#include <stdlib.h>

// Exported by libgrabkernel2.dylib.
extern NSString *getModelIdentifier(void);
extern NSString *getBuild(void);
#include <compression.h>
#include <string.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - HTTP
// ─────────────────────────────────────────────────────────────────────────────

// Synchronous range GET. Returns nil on failure. Retries, because the CDN
// occasionally drops a connection and a megabyte retry is cheap.
static NSData *skRange(NSString *urlString, unsigned long long start,
                       unsigned long long end, NSUInteger tries) {
    if (end < start) return nil;

    const unsigned long long want = end - start + 1;

    for (NSUInteger attempt = 0; attempt < tries; attempt++) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                                        [NSURL URLWithString:urlString]];
        req.timeoutInterval = 30;
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [req setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", start, end]
   forHTTPHeaderField:@"Range"];

        // Ask for the bytes as they are.
        //
        // NSURLSession sends "Accept-Encoding: gzip, deflate" by default, and a
        // response carrying a content encoding cannot be served as a byte range
        // — the server answers 200 with the whole object instead of 206. That
        // alone turns every range request into an 8.5 GB download, and it is
        // exactly the difference between this and a plain curl, which sends no
        // Accept-Encoding and gets a clean 206.
        [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

        __block NSData *body = nil;
        __block NSInteger status = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[NSURLSession.sharedSession dataTaskWithRequest:req
                             completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            body = d;
            if ([r isKindOfClass:NSHTTPURLResponse.class]) {
                status = ((NSHTTPURLResponse *)r).statusCode;
            }
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC));

        // 206 is a range. 200 means the server IGNORED the Range header and is
        // sending the whole object — 8.5 GB for an IPSW.
        //
        // The comment here used to say exactly that and the code returned the
        // body anyway, so a server that ignored Range made the app appear to hang
        // for minutes while it pulled the entire image, and then fail regardless.
        // A 200 is now a hard failure, and it says what came back so the cause is
        // visible instead of mysterious.
        if (status == 200) {
            SKLog(@"[kc] server ignored Range: HTTP 200, %lu bytes (wanted %llu) - giving up",
                  (unsigned long)body.length, want);
            return nil;
        }

        if (status == 206 && body.length == want) return body;

        if (status == 206) {
            SKLog(@"[kc] short range reply: %lu of %llu bytes",
                  (unsigned long)body.length, want);
        } else if (body.length == 0) {
            SKLog(@"[kc] empty reply (HTTP %ld, attempt %lu)",
                  (long)status, (unsigned long)(attempt + 1));
        }

        if (attempt + 1 < tries) usleep(500 * 1000);
    }
    return nil;
}

static NSData *skGet(NSString *urlString) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:urlString]];
    req.timeoutInterval = 30;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __block NSData *body = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:req
                         completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        body = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    return body;
}

static unsigned long long skContentLength(NSString *urlString) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:urlString]];
    req.HTTPMethod = @"HEAD";
    req.timeoutInterval = 30;

    __block unsigned long long len = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:req
                         completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if ([r isKindOfClass:NSHTTPURLResponse.class]) {
            NSString *cl = ((NSHTTPURLResponse *)r).allHeaderFields[@"Content-Length"];
            if (cl) len = strtoull(cl.UTF8String, NULL, 10);
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC));
    return len;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - little-endian readers
// ─────────────────────────────────────────────────────────────────────────────

static uint16_t sk16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t sk32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t sk64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - zip
// ─────────────────────────────────────────────────────────────────────────────

typedef struct {
    char     name[128];
    uint64_t localHeaderOffset;
    uint64_t compressedSize;
    uint64_t uncompressedSize;
    uint16_t method;
} skZipEntry;

// Locate an entry in the central directory, reading the ZIP64 extra field when
// a field is 0xFFFFFFFF. That field is the whole reason this cannot be a naive
// reader: every entry in an IPSW is past the 4 GB mark.
// `exact` selects between two modes:
//   YES — the entry name must equal `want` byte for byte.
//   NO  — `want` is a prefix, and "research" entries are skipped in favour of
//         the shipping "release" one.
static BOOL skFindZipEntry(unsigned long long fileSize, NSString *urlString,
                           const char *want, BOOL exact, skZipEntry *out) {
    const unsigned long long tailLen = 256 * 1024;
    unsigned long long tailStart = fileSize > tailLen ? fileSize - tailLen : 0;
    NSData *tail = skRange(urlString, tailStart, fileSize - 1, 4);
    if (tail.length < 22) {
        SKLog(@"[kc] central directory: tail fetch failed");
        return NO;
    }

    const uint8_t *t = tail.bytes;
    NSUInteger n = tail.length;

    // End of central directory.
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)n - 22; i >= 0; i--) {
        if (sk32(t + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) {
        SKLog(@"[kc] central directory: no EOCD signature in the tail");
        return NO;
    }

    uint64_t cdSize = sk32(t + eocd + 12);
    uint64_t cdOffset = sk32(t + eocd + 16);
    uint64_t entries = sk16(t + eocd + 10);

    // ZIP64: the 32-bit fields above are 0xFFFFFFFF and the real values live in
    // the ZIP64 EOCD, reached through the locator that precedes the EOCD.
    if (cdOffset == 0xFFFFFFFFull || cdSize == 0xFFFFFFFFull || entries == 0xFFFF) {
        NSInteger loc = eocd - 20;
        if (loc >= 0 && sk32(t + loc) == 0x07064b50) {
            uint64_t eocd64FileOff = sk64(t + loc + 8);
            NSInteger e64 = (NSInteger)(eocd64FileOff - tailStart);
            if (e64 < 0 || e64 + 56 > (NSInteger)n || sk32(t + e64) != 0x06064b50) {
                SKLog(@"[kc] zip64 EOCD is outside the fetched tail");
                return NO;
            }
            entries  = sk64(t + e64 + 32);
            cdSize   = sk64(t + e64 + 40);
            cdOffset = sk64(t + e64 + 48);
            SKLog(@"[kc] zip64: %llu entries, cd=0x%llx size=%llu",
                  entries, cdOffset, cdSize);
        } else {
            SKLog(@"[kc] zip64 locator not found");
            return NO;
        }
    }

    // The central directory itself. It is small (tens of KB) but it sits past
    // 4 GB, which is exactly what a naive reader gets wrong.
    NSData *cd = skRange(urlString, cdOffset, cdOffset + cdSize - 1, 4);
    if (cd.length < cdSize) {
        SKLog(@"[kc] central directory fetch failed (%lu of %llu bytes)",
              (unsigned long)cd.length, cdSize);
        return NO;
    }

    const uint8_t *c = cd.bytes;
    uint64_t off = 0;
    while (off + 46 <= cdSize) {
        if (sk32(c + off) != 0x02014b50) break;

        uint16_t method   = sk16(c + off + 10);
        uint64_t csize    = sk32(c + off + 20);
        uint64_t usize    = sk32(c + off + 24);
        uint16_t nameLen  = sk16(c + off + 28);
        uint16_t extraLen = sk16(c + off + 30);
        uint16_t cmtLen   = sk16(c + off + 32);
        uint64_t lho      = sk32(c + off + 42);

        const uint8_t *name = c + off + 46;
        if (off + 46 + nameLen > cdSize) break;

        // ZIP64 extended information: only the fields that were 0xFFFFFFFF are
        // present, in a fixed order. Skipping this is the bug this exists for.
        if (csize == 0xFFFFFFFFull || usize == 0xFFFFFFFFull || lho == 0xFFFFFFFFull) {
            uint64_t eo = off + 46 + nameLen;
            uint64_t ee = eo + extraLen;
            while (eo + 4 <= ee && eo + 4 <= cdSize) {
                uint16_t id = sk16(c + eo);
                uint16_t sz = sk16(c + eo + 2);
                if (id == 0x0001) {
                    uint64_t p = eo + 4;
                    if (usize == 0xFFFFFFFFull && p + 8 <= cdSize) { usize = sk64(c + p); p += 8; }
                    if (csize == 0xFFFFFFFFull && p + 8 <= cdSize) { csize = sk64(c + p); p += 8; }
                    if (lho   == 0xFFFFFFFFull && p + 8 <= cdSize) { lho   = sk64(c + p); p += 8; }
                    break;
                }
                eo += 4 + sz;
            }
        }

        // Compare against the PREFIX's length, not the entry's.
        //
        // The entry name is always longer than the prefix being matched —
        // "kernelcache.release.iphone15" (27 bytes) against "kernelcache.release"
        // (19). Comparing nameLen bytes, as this did, reads past the end of the
        // prefix literal, and requiring strnlen(wantPrefix, nameLen) == nameLen
        // can never hold when nameLen exceeds the prefix. Together they made the
        // kernelcache unmatchable in every IPSW, which is why acquisition failed
        // on every attempt regardless of source.
        size_t plen = strlen(want);
        BOOL hit = (plen > 0 && nameLen < sizeof(out->name)) &&
                   (exact ? (nameLen == plen && memcmp(name, want, plen) == 0)
                          : (nameLen >= plen && memcmp(name, want, plen) == 0));
        if (hit) {

            // In prefix mode, prefer "release" over "research": research builds
            // are the development variant and are not what a retail device boots.
            if (!exact && strstr((const char *)name, "research") != NULL) {
                off += 46 + nameLen + extraLen + cmtLen;
                continue;
            }

            memcpy(out->name, name, nameLen);
            out->name[nameLen] = '\0';
            out->method = method;
            out->compressedSize = csize;
            out->uncompressedSize = usize;
            out->localHeaderOffset = lho;
            return YES;
        }

        off += 46 + nameLen + extraLen + cmtLen;
    }

    SKLog(@"[kc] no central-directory entry %s %s",
          exact ? "named" : "starting with", want);
    return NO;
}

// Fetch and inflate one entry.
// Raw deflate, which is what ZIP method 8 actually is.
//
// uncompress() is the zlib-format one-shot API: it wants the two-byte zlib header
// and the Adler-32 trailer. A ZIP member has neither, so uncompress() rejects the
// very first byte and returns Z_DATA_ERROR (-3) — which is exactly what the
// device log showed for both BuildManifest.plist and the kernelcache, on every
// attempt, while the whole rest of the pipeline (ZIP64 EOCD, central directory,
// entry lookup, byte ranges) had already succeeded.
//
// inflateInit2() with a NEGATIVE windowBits is how zlib is told there is no
// wrapper. -15 is the largest raw window, which is what a ZIP writer uses.
static NSData *skInflateRaw(NSData *in, unsigned long long outSize) {
    if (!in.length || outSize == 0 || outSize > (1ull << 32)) return nil;

    z_stream zs;
    memset(&zs, 0, sizeof zs);
    if (inflateInit2(&zs, -15) != Z_OK) {
        SKLog(@"[kc] inflateInit2 failed");
        return nil;
    }

    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)outSize];
    zs.next_in   = (Bytef *)in.bytes;
    zs.avail_in  = (uInt)in.length;
    zs.next_out  = out.mutableBytes;
    zs.avail_out = (uInt)out.length;

    int rc = inflate(&zs, Z_FINISH);

    if (rc != Z_STREAM_END) {
        SKLog(@"[kc] inflate failed: rc=%d (%s)", rc, zs.msg ? zs.msg : "?");
        inflateEnd(&zs);
        return nil;
    }

    NSUInteger produced = out.length - zs.avail_out;
    inflateEnd(&zs);

    // The central directory records the exact size, so a short result means the
    // stream and the metadata disagree and the output cannot be trusted.
    if (produced != (NSUInteger)outSize) {
        SKLog(@"[kc] inflate produced %lu of %llu bytes",
              (unsigned long)produced, outSize);
        return nil;
    }

    out.length = produced;
    return out;
}

static NSData *skReadZipEntry(unsigned long long fileSize, NSString *urlString,
                              const skZipEntry *e) {
    NSData *lh = skRange(urlString, e->localHeaderOffset, e->localHeaderOffset + 29, 4);
    if (lh.length < 30 || sk32(lh.bytes) != 0x04034b50) {
        SKLog(@"[kc] local header signature invalid at 0x%llx",
              e->localHeaderOffset);
        return nil;
    }
    const uint8_t *l = lh.bytes;
    uint16_t nameLen  = sk16(l + 26);
    uint16_t extraLen = sk16(l + 28);
    unsigned long long dataStart = e->localHeaderOffset + 30 + nameLen + extraLen;

    if (e->compressedSize == 0 || dataStart + e->compressedSize > fileSize) {
        SKLog(@"[kc] entry size is not sane (%llu bytes)", e->compressedSize);
        return nil;
    }

    // Chunked, so a slow hop does not have to deliver 18 MB in one request.
    //
    // Each chunk is reported as it lands. Without that the whole entry download
    // was silent — the first line came only after the last chunk, so a slow or
    // stalled transfer was indistinguishable from a hang.
    const unsigned long long chunk = 4ull << 20;
    NSMutableData *comp = [NSMutableData dataWithCapacity:(NSUInteger)e->compressedSize];
    unsigned long long done = 0;
    SKLog(@"[kc] %s: fetching %llu bytes in %llu chunks",
          e->name, e->compressedSize,
          (e->compressedSize + chunk - 1) / chunk);

    while (done < e->compressedSize) {
        unsigned long long n = e->compressedSize - done;
        if (n > chunk) n = chunk;
        NSData *part = skRange(urlString, dataStart + done, dataStart + done + n - 1, 5);
        if (part.length != n) {
            SKLog(@"[kc] %s: short read at %llu/%llu", e->name, done, e->compressedSize);
            return nil;
        }
        [comp appendData:part];
        done += n;
        SKLog(@"[kc] %s: %llu/%llu", e->name, done, e->compressedSize);
    }

    if (e->method == 0) return comp;
    if (e->method != 8) {
        SKLog(@"[kc] unsupported zip method %u", e->method);
        return nil;
    }

    NSData *plain = skInflateRaw(comp, e->uncompressedSize);
    if (!plain) return nil;

    SKLog(@"[kc] inflated to %lu bytes", (unsigned long)plain.length);
    return plain;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - DER
// ─────────────────────────────────────────────────────────────────────────────

// Walk the DER-encoded IMG4 and return the first OCTET STRING big enough to be
// the payload.
//
// The shape, confirmed against a real IPSW:
//
//     SEQUENCE
//       IA5String "IM4P"
//       IA5String "krnl"
//       IA5String "KernelManagement_host-..."
//       OCTET STRING   <- this
//
// A classic IM4P file has "IM4P" at offset 0 followed by two big-endian sizes.
// This is not that: the magic sits at offset 8 inside a DER wrapper, which is
// why a reader written for the old layout reports a nonsense header size.
static NSData *skDERPayload(NSData *der) {
    const uint8_t *b = der.bytes;
    uint64_t n = der.length;
    if (n < 4 || b[0] != 0x30) return nil;

    // Top-level SEQUENCE header.
    uint64_t off = 1;
    uint64_t len = b[off++];
    if (len & 0x80) {
        uint64_t k = len & 0x7f;
        len = 0;
        for (uint64_t i = 0; i < k; i++) len = (len << 8) | b[off++];
    }
    uint64_t end = off + len;
    if (end > n) end = n;

    while (off + 2 <= end) {
        uint8_t tag = b[off];
        uint64_t l = b[off + 1];
        uint64_t hdr = 2;
        if (l & 0x80) {
            uint64_t k = l & 0x7f;
            l = 0;
            for (uint64_t i = 0; i < k; i++) l = (l << 8) | b[off + 2 + i];
            hdr = 2 + k;
        }
        uint64_t body = off + hdr;
        if (l > 4096 && tag == 0x04) {
            if (body + l > n) l = n - body;
            SKLog(@"[kc] IMG4 payload: OCTET STRING at %llu, %llu bytes",
                  body, l);
            return [NSData dataWithBytesNoCopy:(void *)(b + body)
                                        length:(NSUInteger)l
                                  freeWhenDone:NO];
        }
        if (body + l <= off) break;          // no forward progress
        off = body + l;
    }
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - entry point
// ─────────────────────────────────────────────────────────────────────────────

// Which kernelcache does THIS product restore from?
//
// An IPSW can ship more than one kernelcache.release.* — iPad8,1 carries
// kernelcache.release.ipad8 for iPad8,1 through iPad8,8 and
// kernelcache.release.ipad8b for iPad8,9 through iPad8,12 — and they are not
// interchangeable. Offsets are derived from symbol addresses inside the file, so
// the wrong board yields wrong offsets and the exploit then reads and writes
// through them.
//
// BuildManifest.plist settles it: every BuildIdentity pairs "Ap,ProductType" —
// which is exactly what hw.machine reports — with the KernelCache path it
// restores from. That is an exact answer rather than a guess.
static NSString *skKernelcachePathFromManifest(unsigned long long fileSize,
                                               NSString *urlString,
                                               NSString *productType) {
    if (!productType.length) return nil;

    skZipEntry manifest;
    memset(&manifest, 0, sizeof(manifest));
    if (!skFindZipEntry(fileSize, urlString, "BuildManifest.plist", YES, &manifest)) {
        return nil;
    }

    NSData *data = skReadZipEntry(fileSize, urlString, &manifest);
    if (!data.length) return nil;

    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:0
                                                          format:NULL
                                                           error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;

    for (NSDictionary *bi in ((NSDictionary *)plist)[@"BuildIdentities"]) {
        if (![bi isKindOfClass:NSDictionary.class]) continue;
        if (![bi[@"Ap,ProductType"] isEqual:productType]) continue;

        NSString *path = bi[@"Manifest"][@"KernelCache"][@"Info"][@"Path"];
        if ([path isKindOfClass:NSString.class] && path.length) return path;
    }
    return nil;
}

NSString *SKKernelcacheFetch(NSString *outPath, NSString *firmwareURL) {
    return SKKernelcacheFetchForProduct(outPath, firmwareURL, getModelIdentifier());
}

NSString *SKKernelcacheFetchForProduct(NSString *outPath, NSString *firmwareURL,
                                       NSString *productType) {
    if (!outPath.length) return @"no output path";
    if (!firmwareURL.length) return @"no firmware URL";

    unsigned long long fileSize = skContentLength(firmwareURL);
    if (fileSize < 1024) {
        SKLog(@"[kc] cannot determine IPSW size");
        return @"cannot determine IPSW size";
    }
    SKLog(@"[kc] IPSW is %llu bytes", fileSize);

    skZipEntry entry;
    memset(&entry, 0, sizeof(entry));

    NSString *manifestPath = skKernelcachePathFromManifest(fileSize, firmwareURL, productType);
    if (manifestPath.length &&
        skFindZipEntry(fileSize, firmwareURL, manifestPath.UTF8String, YES, &entry)) {
        SKLog(@"[kc] BuildManifest selects %@ for %@", manifestPath, productType);
    } else {
        if (manifestPath.length) {
            SKLog(@"[kc] BuildManifest names %@ but it is absent; prefix match", manifestPath);
        } else {
            SKLog(@"[kc] no BuildManifest entry for %@; prefix match", productType ?: @"?");
        }
        if (!skFindZipEntry(fileSize, firmwareURL, "kernelcache.release", NO, &entry)) {
            return @"kernelcache entry not found in the IPSW";
        }
    }
    SKLog(@"[kc] found %s: %llu -> %llu bytes, method %u, lho 0x%llx",
          entry.name, entry.compressedSize, entry.uncompressedSize,
          entry.method, entry.localHeaderOffset);

    NSData *entryData = skReadZipEntry(fileSize, firmwareURL, &entry);
    if (!entryData.length) return @"could not read the kernelcache entry";

    // The inflated entry is the artifact. Nothing further is required.
    //
    // iskcachevalid() in offsets.m accepts a file whose first two bytes are
    // 0x30 0x84 — a DER SEQUENCE — and libxpf parses that directly, LZFSE
    // payload and all. So the DER/IMG4 is the OUTPUT, not an intermediate:
    // decoding it into a raw Mach-O would produce a file the caller rejects.
    //
    // (That also rules out LZFSE as the reason libgrabkernel2 fails. It never
    // decodes the payload either; it fails earlier, on the ZIP64 offsets.)
    const uint8_t *e = entryData.bytes;
    if (entryData.length < 2 || e[0] != 0x30 || e[1] != 0x84) {
        SKLog(@"[kc] entry does not start with 30 84 (got %02x %02x)",
              entryData.length > 0 ? e[0] : 0, entryData.length > 1 ? e[1] : 0);
        return @"kernelcache entry is not a DER IMG4";
    }

    // Purely informational: report what the payload is wrapped with.
    NSData *payload = skDERPayload(entryData);
    if (payload.length >= 4) {
        const uint8_t *q = payload.bytes;
        SKLog(@"[kc] IMG4 payload: %lu bytes, magic %.4s",
              (unsigned long)payload.length, (const char *)q);
    }

    NSError *err = nil;
    if (![entryData writeToFile:outPath options:NSDataWritingAtomic error:&err]) {
        SKLog(@"[kc] write failed: %@", err.localizedDescription);
        return @"could not write the kernelcache";
    }

    SKLog(@"[kc] wrote %lu bytes (DER IMG4) to %@",
          (unsigned long)entryData.length, outPath);
    return nil;
}
