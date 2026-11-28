//
//  SKIPAManager.m
//  AppDump — IPA 管理的模型与文件操作
//
//  解析全部在内存里按需读：先读 zip 尾部找到 EOCD（必要时再走 ZIP64），
//  顺序遍历中央目录建立「文件名 -> 本地头偏移」索引，然后只对需要看的条目
//  （Info.plist、主程序、扩展的可执行文件、CodeResources）读前若干 KB。
//  不展开、不解压整包，几百 MB 的包也是毫秒级。
//
#import "SKIPAManager.h"
#import "ADXInternal.h"

#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <zlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#pragma mark - ZIP 读取

// 一次 Central Directory 扫描的结果
typedef struct {
    NSUInteger count;
    unsigned long long uncompressed;
    NSDictionary<NSString *, NSNumber *> * _Nullable index;
} sk_cd_result;

@interface SKZipFile : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSNumber *> *index;  // name -> 本地头偏移
@property (nonatomic, assign) NSUInteger entryCount;
@property (nonatomic, assign) unsigned long long uncompressed;
- (nullable instancetype)initWithPath:(NSString *)path;
/// 某条目从数据起点开始的连续字节（至多 maxBytes）。method 回传压缩方式。
- (nullable NSData *)readEntry:(NSString *)name
                      maxBytes:(NSUInteger)maxBytes
                     methodOut:(nullable uint16_t *)method
                     sizeOut:(nullable unsigned long long *)entrySize;
@end

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t rd64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)p[i] << (8 * i);
    return v;
}

@implementation SKZipFile {
    int _fd;
    unsigned long long _fileSize;
}

- (nullable instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;
    _path = [path copy];
    _fd = -1;
    if (!path.length) return self;
    _fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (_fd < 0) return self;
    struct stat st;
    if (fstat(_fd, &st) != 0 || st.st_size < 22) { close(_fd); _fd = -1; return self; }
    _fileSize = (unsigned long long)st.st_size;

    sk_cd_result cd = [self loadCentralDirectory];
    if (!cd.index.count) {
        close(_fd); _fd = -1;
        return self;   // fd 已关，index 为空 = 不是合法 zip
    }
    _index = cd.index;
    _entryCount = cd.count;
    _uncompressed = cd.uncompressed;
    return self;
}

- (void)dealloc {
    if (_fd >= 0) close(_fd);
}

- (nullable NSData *)pread:(NSUInteger)len at:(unsigned long long)off {
    if (_fd < 0 || off >= _fileSize) return nil;
    if (off + len > _fileSize) len = (NSUInteger)(_fileSize - off);
    NSMutableData *d = [NSMutableData dataWithLength:len];
    void *buf = d.mutableBytes;
    NSUInteger done = 0;
    while (done < len) {
        ssize_t got = pread(_fd, (uint8_t *)buf + done, len - done, (off_t)(off + done));
        if (got <= 0) break;
        done += (NSUInteger)got;
    }
    if (done == 0) return nil;
    d.length = done;
    return d;
}

- (sk_cd_result)loadCentralDirectory {
    const NSUInteger tail = (NSUInteger)MIN((unsigned long long)65557, _fileSize);
    NSData *t = [self pread:tail at:_fileSize - tail];
    sk_cd_result res = {0, 0, nil};
    if (t.length < 22) return res;
    const uint8_t *p = t.bytes;

    NSInteger eocd = -1;
    unsigned long long eocdAbs = 0;
    for (NSInteger i = (NSInteger)t.length - 22; i >= 0; i--) {
        if (p[i] == 0x50 && p[i + 1] == 0x4b && p[i + 2] == 0x05 && p[i + 3] == 0x06) {
            uint16_t clen = rd16(p + i + 20);
            if ((NSUInteger)(i + 22 + clen) <= t.length) {
                eocd = i;
                eocdAbs = _fileSize - tail + (unsigned long long)i;
                break;
            }
        }
    }
    if (eocd < 0) return res;

    const uint8_t *e = p + eocd;
    unsigned long long count = rd16(e + 10);
    unsigned long long cdSize = rd32(e + 12);
    unsigned long long cdOff = rd32(e + 16);

    if (count == 0xffff || cdSize == 0xffffffffU || cdOff == 0xffffffffU) {
        if (eocdAbs >= 20) {
            NSData *loc = [self pread:20 at:eocdAbs - 20];
            const uint8_t *q = loc.bytes;
            if (loc.length == 20 && q[0] == 0x50 && q[1] == 0x4b && q[2] == 0x06 && q[3] == 0x07) {
                unsigned long long z64 = rd64(q + 8);
                NSData *r = [self pread:56 at:z64];
                const uint8_t *s = r.bytes;
                if (r.length >= 56 && s[0] == 0x50 && s[1] == 0x4b && s[2] == 0x06 && s[3] == 0x06) {
                    count = rd64(s + 32);
                    cdSize = rd64(s + 40);
                    cdOff = rd64(s + 48);
                }
            }
        }
    }
    if (cdOff >= _fileSize || cdOff + cdSize > _fileSize || cdSize == 0) {
        // 有些打包器写错大小；只要起点合理就按到文件尾解析
        if (cdOff >= _fileSize) return res;
        cdSize = _fileSize - cdOff;
    }

    // 一次把中央目录读进来（几 MB 以内），再顺序解析
    NSUInteger maxRead = 64u << 20;
    NSData *cd = [self pread:(NSUInteger)MIN(cdSize, (unsigned long long)maxRead) at:cdOff];
    if (!cd || cd.length < 46) return res;
    const uint8_t *b = cd.bytes;
    NSUInteger len = cd.length;

    NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)MIN(count, 4096)];
    unsigned long long total = 0;
    NSUInteger pos = 0;
    NSUInteger got = 0;

    while (pos + 46 <= len && got < count) {
        const uint8_t *h = b + pos;
        if (!(h[0] == 0x50 && h[1] == 0x4b && h[2] == 0x01 && h[3] == 0x02)) break;
        uint16_t nameLen = rd16(h + 28);
        uint16_t extraLen = rd16(h + 30);
        uint16_t cmtLen = rd16(h + 32);
        uint32_t usize = rd32(h + 24);
        uint32_t csize = rd32(h + 20);
        uint32_t localOff = rd32(h + 42);
        NSUInteger next = pos + 46 + nameLen + extraLen + cmtLen;
        if (next > len) break;

        unsigned long long lo = localOff;
        if (usize == 0xffffffffU || csize == 0xffffffffU || localOff == 0xffffffffU) {
            NSUInteger f = pos + 46 + nameLen;
            NSUInteger fend = f + extraLen;
            while (f + 4 <= fend) {
                uint16_t tag = rd16(b + f);
                uint16_t sz = rd16(b + f + 2);
                if (tag == 0x0001) {
                    NSUInteger d = f + 4;
                    NSUInteger dend = MIN(d + sz, fend);
                    if (usize == 0xffffffffU && d + 8 <= dend) d += 8;       // 跳过 usize
                    if (csize == 0xffffffffU && d + 8 <= dend) d += 8;       // 跳过 csize
                    if (localOff == 0xffffffffU && d + 8 <= dend) lo = rd64(b + d);
                    break;
                }
                f = (NSUInteger)(f + 4 + sz);
            }
        }

        NSString *name = [[NSString alloc] initWithBytes:h + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithBytes:h + 46 length:nameLen encoding:NSISOLatin1StringEncoding];
        if (name.length) {
            map[name] = @((unsigned long long)lo);
            if (usize != 0xffffffffU) total += usize;
            got++;
        }
        pos = next;
    }

    if (!map.count) return res;
    res.count = got;
    res.uncompressed = total;
    res.index = map;
    return res;
}

- (nullable NSData *)readEntry:(NSString *)name
                      maxBytes:(NSUInteger)maxBytes
                     methodOut:(uint16_t *)method
                       sizeOut:(unsigned long long *)entrySize {
    NSNumber *offN = _index[name];
    if (!offN) return nil;
    unsigned long long off = offN.unsignedLongLongValue;
    NSData *lh = [self pread:30 at:off];
    if (lh.length < 30) return nil;
    const uint8_t *h = lh.bytes;
    if (!(h[0] == 0x50 && h[1] == 0x4b && h[2] == 0x03 && h[3] == 0x04)) return nil;
    uint16_t nm = rd16(h + 26);
    uint16_t ex = rd16(h + 28);
    uint16_t m = rd16(h + 8);
    uint32_t cs = rd32(h + 18);
    unsigned long long dataOff = off + 30 + nm + ex;
    if (dataOff >= _fileSize) return nil;
    if (cs == 0 || cs == 0xffffffffU) cs = (uint32_t)MIN((unsigned long long)0x7fffffffULL, _fileSize - dataOff);
    NSUInteger want = (NSUInteger)MIN((unsigned long long)maxBytes, (unsigned long long)cs);
    if (method) *method = m;
    if (entrySize) *entrySize = cs;
    return [self pread:want at:dataOff];
}

@end

#pragma mark - Mach-O 解析

static NSString *sk_cpu_name(cpu_type_t type, cpu_subtype_t sub) {
    if (type == CPU_TYPE_ARM64) {
        cpu_subtype_t s = (cpu_subtype_t)(sub & 0x00ffffff);
        if (s == CPU_SUBTYPE_ARM64E) return @"arm64e";
        if (s == CPU_SUBTYPE_ARM64_V8) return @"arm64v8";
        return @"arm64";
    }
    if (type == CPU_TYPE_ARM) return @"arm";
    if (type == CPU_TYPE_X86_64) return @"x86_64";
    return [NSString stringWithFormat:@"cpu(%d,%d)", type, sub];
}

typedef void (^SKSliceBlock)(const uint8_t *base, NSUInteger len, NSString *arch);

static void sk_walk_macho(const uint8_t *buf, NSUInteger len, SKSliceBlock block) {
    if (!buf || len < 28) return;
    uint32_t magic;
    memcpy(&magic, buf, 4);
    if (magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
        BOOL swap = (magic == FAT_CIGAM || magic == FAT_CIGAM_64);
        BOOL is64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
        uint32_t n = ((const struct fat_header *)buf)->nfat_arch;
        if (swap) n = OSSwapInt32(n);
        NSUInteger entsz = is64 ? 32 : 20;
        if (n == 0 || n > 16 || 8 + (NSUInteger)n * entsz > len) return;
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *e = buf + 8 + (NSUInteger)i * entsz;
            cpu_type_t ct; cpu_subtype_t cst;
            unsigned long long ofs = 0, size = 0;
            memcpy(&ct, e, 4); memcpy(&cst, e + 4, 4);
            if (is64) { ofs = rd64(e + 8); size = rd64(e + 16); }
            else { ofs = rd32(e + 8); size = rd32(e + 12); }
            if (swap) {
                ct = OSSwapInt32(ct); cst = OSSwapInt32(cst);
                if (is64) { ofs = OSSwapInt64(ofs); size = OSSwapInt64(size); }
                else { ofs = OSSwapInt32((uint32_t)ofs); size = OSSwapInt32((uint32_t)size); }
            }
            if (ofs + size > len || size < 28) continue;
            block(buf + ofs, (NSUInteger)size, sk_cpu_name(ct, cst));
        }
        return;
    }
    if (magic == MH_MAGIC || magic == MH_MAGIC_64) {
        const struct mach_header_64 *m = (const struct mach_header_64 *)buf;
        block(buf, len, sk_cpu_name(m->cputype, m->cpusubtype));
    }
}

/// 返回 YES = 该切片仍是密文。hasCrypt 回传是否有 LC_ENCRYPTION_INFO。
static BOOL sk_slice_is_encrypted(const uint8_t *base, NSUInteger len, BOOL *hasCrypt) {
    if (len < 32) return NO;
    uint32_t magic;
    memcpy(&magic, base, 4);
    BOOL is64 = (magic == MH_MAGIC_64);
    if (!is64 && magic != MH_MAGIC) return NO;
    NSUInteger hdr = is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    uint32_t ncmds = 0;
    memcpy(&ncmds, base + 16, 4);
    if (ncmds == 0 || ncmds > 8192) return NO;
    NSUInteger p = hdr;
    for (uint32_t i = 0; i < ncmds && p + 8 <= len; i++) {
        uint32_t cmd, cmdsize;
        memcpy(&cmd, base + p, 4);
        memcpy(&cmdsize, base + p + 4, 4);
        if (cmdsize < 8 || p + cmdsize > len) break;
        if (cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64) {
            if (cmdsize >= 20) {
                uint32_t cryptid = 0;
                memcpy(&cryptid, base + p + 16, 4);
                *hasCrypt = YES;
                return cryptid != 0;
            }
        }
        p += cmdsize;
    }
    return NO;
}

#pragma mark - SKIPA

@implementation SKIPABinary
@end

@implementation SKIPA

- (instancetype)init {
    self = [super init];
    if (self) {
        _notes = [NSMutableArray array];
        _binaries = @[];
        _archs = @[];
        _integrity = SKIPAIntegrityUnknown;
    }
    return self;
}

- (NSString *)variant {
    if (!self.analyzed) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (self.archs.count) [parts addObject:[self.archs componentsJoinedByString:@"+"]];
    if (self.binaries.count) [parts addObject:self.encrypted ? @"未解密" : @"已解密"];
    if (self.integrity == SKIPAIntegrityBroken) [parts addObject:@"结构异常"];
    if (self.integrity == SKIPAIntegrityUnknown) [parts addObject:@"无法读取"];
    return parts.count ? [parts componentsJoinedByString:@" · "] : nil;
}

@end

#pragma mark - 扫描

NSString *SKIPADocumentsPath(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

SKIPA *SKIPAMakeShallow(NSString *path) {
    SKIPA *ipa = [SKIPA new];
    ipa.path = path;
    ipa.fileName = path.lastPathComponent;
    NSString *lower = ipa.fileName.lowercaseString;
    NSRange dot = [lower rangeOfString:@".ipa" options:NSBackwardsSearch];
    ipa.appName = (dot.location != NSNotFound && dot.location > 0) ? [ipa.fileName substringToIndex:dot.location]
                                                                   : [ipa.fileName stringByDeletingPathExtension];
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    ipa.fileSize = [a[NSFileSize] unsignedLongLongValue];
    ipa.modified = a[NSFileModificationDate] ?: [NSDate date];
    return ipa;
}

NSArray<SKIPA *> *SKIPAScan(void) {
    NSString *docs = SKIPADocumentsPath();
    NSMutableArray<SKIPA *> *out = [NSMutableArray array];
    if (!docs.length) return out;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObjects:docs, nil];
    NSUInteger visited = 0;

    while (stack.count && visited < 20000) {
        NSString *dir = stack.lastObject;
        [stack removeLastObject];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *name in items) {
            if (++visited > 20000) break;
            if ([name hasPrefix:@"."]) continue;   // .tmp_ 砸壳工作目录 / 隐藏文件
            NSString *full = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) {
                NSNumber *depth = @([[full componentsSeparatedByString:@"/"] count] - [docs componentsSeparatedByString:@"/"].count);
                if (depth.integerValue <= 4) [stack addObject:full];
            } else if ([name.pathExtension.lowercaseString isEqualToString:@"ipa"]) {
                [out addObject:SKIPAMakeShallow(full)];
            }
        }
    }

    [out sortUsingComparator:^NSComparisonResult(SKIPA *a, SKIPA *b) {
        return [b.modified compare:a.modified];
    }];
    return out;
}

#pragma mark - plist

static NSDictionary *sk_plist_from_bytes(NSData *d) {
    if (d.length < 8) return nil;
    id obj = nil;
    @try {
        obj = [NSPropertyListSerialization propertyListWithData:d
                                                        options:NSPropertyListImmutable
                                                         format:NULL
                                                          error:NULL];
    } @catch (NSException *e) {
        obj = nil;
    }
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

/// 读包内一个 plist。stored（method 0）直接解；deflate 的就地 inflate 到 4MB。
static NSDictionary *sk_read_plist(SKZipFile *zip, NSString *name) {
    if (!name.length) return nil;
    uint16_t method = 0;
    unsigned long long total = 0;
    NSData *raw = [zip readEntry:name maxBytes:(4u << 20) methodOut:&method sizeOut:&total];
    if (!raw.length) return nil;
    if (method == 0) return sk_plist_from_bytes(raw);
    if (method != 8) return nil;

    NSMutableData *out = [NSMutableData dataWithLength:(4u << 20)];
    z_stream zs;
    memset(&zs, 0, sizeof zs);
    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) return nil;
    zs.next_in = (Bytef *)raw.bytes;
    zs.avail_in = (uInt)raw.length;
    zs.next_out = out.mutableBytes;
    zs.avail_out = (uInt)out.length;
    inflate(&zs, Z_FINISH);
    NSUInteger produced = out.length - zs.avail_out;
    inflateEnd(&zs);
    if (!produced) return nil;
    out.length = produced;
    return sk_plist_from_bytes(out);
}

#pragma mark - 深分析

void SKIPAAnalyze(SKIPA *ipa) {
    if (!ipa || ipa.analyzed) return;

    SKZipFile *zip = [[SKZipFile alloc] initWithPath:ipa.path ?: @""];
    if (!zip || !zip.index.count) {
        ipa.integrity = SKIPAIntegrityUnknown;
        ipa.problem = ipa.fileSize == 0 ? @"文件是空的" : @"不是有效的 IPA（zip 结构损坏或已截断）";
        [ipa.notes addObject:ipa.problem];
        ipa.analyzed = YES;
        return;
    }

    ipa.entryCount = zip.entryCount;
    ipa.uncompressedTotal = zip.uncompressed;

    NSArray<NSString *> *allNames = zip.index.allKeys;

    // ── 1. 定位 Payload 下的 .app（一层 = 主包，两层 = 扩展 / Watch） ──
    NSString *mainPrefix = nil;
    NSMutableArray<NSString *> *extPrefixes = [NSMutableArray array];
    BOOL hasWatch = NO;

    for (NSString *name in allNames) {
        NSArray<NSString *> *parts = [name pathComponents];
        NSUInteger payload = NSNotFound;
        for (NSUInteger i = 0; i < parts.count; i++) {
            if ([parts[i] caseInsensitiveCompare:@"Payload"] == NSOrderedSame) { payload = i; break; }
        }
        if (payload == NSNotFound || payload + 2 >= parts.count) continue;
        if ([parts.lastObject caseInsensitiveCompare:@"Info.plist"] != NSOrderedSame) continue;

        NSUInteger appIdx = NSNotFound;
        for (NSUInteger i = payload + 1; i + 1 < parts.count; i++) {
            if ([parts[i].lowercaseString hasSuffix:@".app"]) appIdx = i;
        }
        if (appIdx == NSNotFound) continue;

        NSRange pre = NSMakeRange(0, appIdx + 1);
        NSString *prefix = [[parts subarrayWithRange:pre] componentsJoinedByString:@"/"];
        if ([prefix containsString:@"/Watch/"]) hasWatch = YES;

        BOOL isMain = (appIdx == payload + 1);
        if (isMain) {
            if (!mainPrefix) mainPrefix = prefix;
        } else if (![extPrefixes containsObject:prefix]) {
            [extPrefixes addObject:prefix];
        }
    }
    ipa.hasWatchApp = hasWatch;
    ipa.hasExtensions = extPrefixes.count > 0;

    if (!mainPrefix) {
        ipa.integrity = SKIPAIntegrityBroken;
        ipa.problem = @"包里没有 Payload/*.app";
        [ipa.notes addObject:ipa.problem];
        ipa.analyzed = YES;
        return;
    }

    // 签名：主包自带 _CodeSignature/CodeResources
    ipa.signed = NO;
    for (NSString *n in allNames) {
        if ([n hasPrefix:[mainPrefix stringByAppendingString:@"/"] ] &&
            [n rangeOfString:@"/_CodeSignature/CodeResources" options:NSBackwardsSearch].location != NSNotFound) {
            ipa.signed = YES;
            break;
        }
    }

    // ── 2. 主 Info.plist ──
    NSString *appInfo = [mainPrefix stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = nil;
    for (NSString *n in allNames) {
        if ([n caseInsensitiveCompare:appInfo] == NSOrderedSame) { info = sk_read_plist(zip, n); break; }
    }
    if (info) {
        NSString *disp = info[@"CFBundleDisplayName"];
        NSString *nm = info[@"CFBundleName"];
        if ([disp isKindOfClass:NSString.class] && disp.length) ipa.appName = disp;
        else if ([nm isKindOfClass:NSString.class] && nm.length) ipa.appName = nm;
        if ([info[@"CFBundleIdentifier"] isKindOfClass:NSString.class]) ipa.bundleID = info[@"CFBundleIdentifier"];
        NSString *sv = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : nil;
        NSString *bv = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : nil;
        if (sv.length && bv.length && ![sv isEqualToString:bv]) ipa.version = [NSString stringWithFormat:@"%@ (%@)", sv, bv];
        else if (sv.length || bv.length) ipa.version = sv.length ? sv : bv;
        if ([info[@"MinimumOSVersion"] isKindOfClass:NSString.class]) ipa.minimumOS = info[@"MinimumOSVersion"];
        if ([info[@"CFBundleExecutable"] isKindOfClass:NSString.class]) ipa.executable = info[@"CFBundleExecutable"];
    } else {
        ipa.hasAppLessMain = YES;
        [ipa.notes addObject:@"主程序 Info.plist 读取失败"];
    }

    if (ipa.bundleID.length) {
        NSString *bid = ipa.bundleID;
        if ([bid hasSuffix:@".debug"] || [bid containsString:@"modified"] || [bid hasSuffix:@"-inhouse"]) {
            ipa.isCustomBundleID = YES;
        }
    }

    // ── 3. 扩展类型统计 ──
    NSMutableDictionary<NSString *, NSNumber *> *extKind = [NSMutableDictionary dictionary];
    for (NSString *prefix in extPrefixes) {
        if ([prefix containsString:@"/Watch/"]) continue;
        NSString *extInfo = [prefix stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *ei = nil;
        for (NSString *n in allNames) {
            if ([n caseInsensitiveCompare:extInfo] == NSOrderedSame) { ei = sk_read_plist(zip, n); break; }
        }
        NSString *point = nil;
        id nx = ei[@"NSExtension"];
        if ([nx isKindOfClass:NSDictionary.class] && [nx[@"NSExtensionPointIdentifier"] isKindOfClass:NSString.class]) {
            point = nx[@"NSExtensionPointIdentifier"];
        }
        NSString *kind = @"扩展";
        if ([point containsString:@"share"]) kind = @"共享扩展";
        else if ([point containsString:@"widget"]) kind = @"Widget";
        else if ([point containsString:@"notification"]) kind = @"通知";
        else if ([point containsString:@"intent"]) kind = @"快捷指令";
        else if ([point containsString:@"keyboard"]) kind = @"键盘";
        else if ([point containsString:@"audio"]) kind = @"音频";
        else if ([point containsString:@"fileprovider"]) kind = @"文件提供器";
        extKind[kind] = @(extKind[kind].unsignedIntegerValue + 1);
    }
    if (extKind.count) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *k in @[ @"共享扩展", @"Widget", @"通知", @"快捷指令", @"键盘", @"音频", @"文件提供器", @"扩展" ]) {
            NSNumber *c = extKind[k];
            if (c) [parts addObject:[NSString stringWithFormat:@"%@ ×%lu", k, (unsigned long)c.unsignedIntegerValue]];
        }
        ipa.extensionSummary = [parts componentsJoinedByString:@"、"];
    }
    if (ipa.hasWatchApp) [ipa.notes addObject:@"包含 Apple Watch 配套包"];

    // ── 4. 主程序 + 扩展可执行文件 ──
    NSString *stem = [mainPrefix.lastPathComponent stringByDeletingPathExtension];
    NSString *exe = ipa.executable.length ? ipa.executable : stem;

    NSMutableArray<NSString *> *exeKeys = [NSMutableArray array];
    NSString *mainExe = [mainPrefix stringByAppendingPathComponent:exe];
    for (NSString *n in allNames) {
        if ([n caseInsensitiveCompare:mainExe] == NSOrderedSame) { [exeKeys addObject:n]; break; }
    }
    for (NSString *prefix in extPrefixes) {
        if ([prefix containsString:@"/Watch/"]) continue;
        NSString *ps = [prefix.lastPathComponent stringByDeletingPathExtension];
        NSString *wanted = [prefix stringByAppendingPathComponent:ps];
        for (NSString *n in allNames) {
            if ([n caseInsensitiveCompare:wanted] == NSOrderedSame) { [exeKeys addObject:n]; break; }
        }
    }

    NSMutableArray<SKIPABinary *> *bins = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *archSet = [NSMutableOrderedSet orderedSet];

    for (NSString *key in exeKeys) {
        uint16_t method = 0;
        unsigned long long total = 0;
        NSData *head = [zip readEntry:key maxBytes:(512 << 10) methodOut:&method sizeOut:&total];
        NSMutableData *bytes = [head mutableCopy];
        if (method != 0) {
            NSMutableData *out = [NSMutableData dataWithLength:(512 << 10)];
            z_stream zs;
            memset(&zs, 0, sizeof zs);
            bytes = nil;
            if (inflateInit2(&zs, -MAX_WBITS) == Z_OK) {
                zs.next_in = (Bytef *)head.bytes;
                zs.avail_in = (uInt)head.length;
                zs.next_out = out.mutableBytes;
                zs.avail_out = (uInt)out.length;
                inflate(&zs, Z_FINISH);
                NSUInteger produced = out.length - zs.avail_out;
                inflateEnd(&zs);
                if (produced) { out.length = produced; bytes = out; }
            }
        }

        SKIPABinary *bin = [SKIPABinary new];
        bin.path = key;
        bin.size = total;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        __block unsigned long nEnc = 0, nCrypt = 0;   // ARC 下改基本类型要先提升为 __block
        if (bytes.length) {
            sk_walk_macho(bytes.bytes, bytes.length, ^(const uint8_t *base, NSUInteger len, NSString *arch) {
                [names addObject:arch];
                BOOL hc = NO;
                if (sk_slice_is_encrypted(base, len, &hc)) nEnc++;
                if (hc) nCrypt++;
            });
        } else {
            [ipa.notes addObject:[NSString stringWithFormat:@"%@ 无法解析（只支持 stored / deflate）", key.lastPathComponent]];
        }
        BOOL anyEnc = nEnc > 0, anyCrypt = nCrypt > 0;
        bin.archs = [names componentsJoinedByString:@", "];
        bin.encrypted = anyEnc;
        bin.hasCryptInfo = anyCrypt;
        [bins addObject:bin];
        for (NSString *a in names) [archSet addObject:a];
        if (anyEnc) ipa.encrypted = YES;
    }

    if (!exeKeys.count) [ipa.notes addObject:@"包里找不到主程序二进制"];

    ipa.binaries = bins;
    ipa.archs = archSet.array;

    // ── 5. 结论 ──
    if (!bins.count) {
        ipa.integrity = SKIPAIntegrityBroken;
        ipa.problem = @"包里没有可解析的 Mach-O";
    } else if (!ipa.signed) {
        ipa.integrity = SKIPAIntegrityBroken;
        ipa.problem = @"缺少 _CodeSignature（未签名或签名被删）";
    } else {
        ipa.integrity = SKIPAIntegrityOk;
    }
    if (ipa.problem) [ipa.notes addObject:ipa.problem];

    if (ipa.encrypted) {
        NSUInteger enc = 0;
        for (SKIPABinary *b in bins) if (b.encrypted) enc++;
        [ipa.notes addObject:[NSString stringWithFormat:@"仍有 %lu/%lu 个二进制带 cryptid，装上启动大概率闪退",
                              (unsigned long)enc, (unsigned long)bins.count]];
    } else if (bins.count) {
        [ipa.notes addObject:@"全部二进制已清 cryptid，可直接安装"];
    }

    ipa.analyzed = YES;
}

#pragma mark - 操作

NSArray<NSString *> *SKIPADelete(NSArray<SKIPA *> *items) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (SKIPA *ipa in items) {
        NSString *path = ipa.path;
        if (!path.length) continue;
        // 砸壳产物旁边可能有同名 .plist 元数据或解开的 .app 目录，一并清掉
        NSString *stemPath = path.stringByDeletingPathExtension;
        NSArray<NSString *> *siblings = @[ path,
                                           [stemPath stringByAppendingPathExtension:@"plist"],
                                           stemPath ];
        NSError *err = nil;
        BOOL removed = NO;
        for (NSString *p in siblings) {
            if (![fm fileExistsAtPath:p]) continue;
            NSError *e = nil;
            if ([fm removeItemAtPath:p error:&e]) removed = YES;
            else if (!err) err = e;
        }
        if (!removed) {
            chmod(path.fileSystemRepresentation, 0700);
            NSError *e = nil;
            if ([fm removeItemAtPath:path error:&e]) removed = YES;
            else err = e;
        }
        if (removed) {
            ADXLogf(@"ipa: 已删除 %@", ipa.fileName);
        } else {
            [errors addObject:[NSString stringWithFormat:@"%@：%@", ipa.fileName,
                               err.localizedDescription ?: @"删除失败"]];
        }
    }
    return errors;
}

BOOL SKIPARename(SKIPA *ipa, NSString *newName, NSError **error) {
    NSString *clean = [(newName ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    clean = [clean stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    if (!clean.length) {
        if (error) *error = [NSError errorWithDomain:@"SKIPA" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"名字不能为空" }];
        return NO;
    }
    if (![clean.lowercaseString hasSuffix:@".ipa"]) clean = [clean stringByAppendingString:@".ipa"];
    NSString *dst = [ipa.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:clean];
    if ([dst isEqualToString:ipa.path]) return YES;
    if ([NSFileManager.defaultManager fileExistsAtPath:dst]) {
        if (error) *error = [NSError errorWithDomain:@"SKIPA" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"同名文件已存在" }];
        return NO;
    }
    NSError *e = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:ipa.path toPath:dst error:&e]) {
        if (error) *error = e;
        return NO;
    }
    ipa.path = dst;
    ipa.fileName = clean;
    return YES;
}

#pragma mark - 包内浏览

NSArray<NSDictionary<NSString *, id> *> *SKIPAListEntries(SKIPA *ipa, NSString *prefix, NSUInteger *totalOut) {
    SKZipFile *zip = [[SKZipFile alloc] initWithPath:ipa.path ?: @""];
    NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
    if (!zip.index.count) return out;

    NSString *base = prefix.length ? [prefix stringByAppendingString:@"/"] : @"";
    NSMutableDictionary<NSString *, NSNumber *> *dirs = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *files = [NSMutableArray array];

    for (NSString *name in zip.index.allKeys) {
        if (base.length && ![name hasPrefix:base]) continue;
        NSString *rest = base.length ? [name substringFromIndex:base.length] : name;
        if (!rest.length) continue;
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location == NSNotFound) {
            [files addObject:rest];
        } else {
            NSString *d = [rest substringToIndex:slash.location];
            dirs[d] = @(dirs[d].integerValue + 1);
        }
    }
    if (totalOut) *totalOut = (NSUInteger)zip.entryCount;

    NSArray<NSString *> *sortedDirs = [dirs.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSArray<NSString *> *sortedFiles = [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *d in sortedDirs) {
        [out addObject:@{ @"name" : d, @"dir" : @YES, @"count" : dirs[d] }];
    }
    for (NSString *f in sortedFiles) {
        NSNumber *off = zip.index[[base stringByAppendingString:f]];
        [out addObject:@{ @"name" : f, @"dir" : @NO, @"count" : @0, @"offset" : off ?: @0 }];
    }
    return out;
}

NSData *SKIPAReadEntry(SKIPA *ipa, NSString *entry, NSUInteger maxBytes) {
    SKZipFile *zip = [[SKZipFile alloc] initWithPath:ipa.path ?: @""];
    if (!zip.index.count) return nil;
    uint16_t method = 0;
    unsigned long long total = 0;
    NSData *raw = [zip readEntry:entry maxBytes:maxBytes methodOut:&method sizeOut:&total];
    if (!raw.length) return nil;
    if (method == 0) return raw;
    if (method != 8) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:maxBytes];
    z_stream zs;
    memset(&zs, 0, sizeof zs);
    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) return nil;
    zs.next_in = (Bytef *)raw.bytes;
    zs.avail_in = (uInt)raw.length;
    zs.next_out = out.mutableBytes;
    zs.avail_out = (uInt)out.length;
    inflate(&zs, Z_FINISH);
    NSUInteger produced = out.length - zs.avail_out;
    inflateEnd(&zs);
    if (!produced) return nil;
    out.length = produced;
    return out;
}

unsigned long long SKIPATotalSize(NSArray<SKIPA *> *items) {
    unsigned long long t = 0;
    for (SKIPA *i in items) t += i.fileSize;
    return t;
}

NSString *SKIPAReportText(SKIPA *ipa) {
    if (!ipa) return @"";
    if (!ipa.analyzed) SKIPAAnalyze(ipa);
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"文件：%@\n", ipa.fileName];
    [s appendFormat:@"大小：%@\n", ADXBytesText(ipa.fileSize)];
    [s appendFormat:@"修改：%@\n", [NSDateFormatter localizedStringFromDate:ipa.modified
                                                                dateStyle:NSDateFormatterMediumStyle
                                                                timeStyle:NSDateFormatterShortStyle]];
    [s appendFormat:@"应用：%@\n", ipa.appName ?: @"—"];
    [s appendFormat:@"Bundle ID：%@\n", ipa.bundleID ?: @"—"];
    [s appendFormat:@"版本：%@\n", ipa.version ?: @"—"];
    [s appendFormat:@"最低系统：iOS %@\n", ipa.minimumOS ?: @"—"];
    [s appendFormat:@"架构：%@\n", ipa.archs.count ? [ipa.archs componentsJoinedByString:@", "] : @"—"];
    NSString *state = ipa.integrity == SKIPAIntegrityOk ? @"完整"
                     : ipa.integrity == SKIPAIntegrityBroken ? [NSString stringWithFormat:@"异常（%@）", ipa.problem ?: @"未知"]
                     : @"无法读取";
    [s appendFormat:@"结构：%@\n", state];
    [s appendFormat:@"签名：%@\n", ipa.signed ? @"有 _CodeSignature" : @"无"];
    [s appendFormat:@"加密：%@\n", ipa.encrypted ? @"仍有密文" : (ipa.binaries.count ? @"已解密" : @"未检测")];
    [s appendFormat:@"条目：%lu 个，解压后 %@\n", (unsigned long)ipa.entryCount, ADXBytesText(ipa.uncompressedTotal)];
    if (ipa.extensionSummary.length) [s appendFormat:@"扩展：%@\n", ipa.extensionSummary];
    if (ipa.hasWatchApp) [s appendString:@"含 Watch 包\n"];
    for (SKIPABinary *b in ipa.binaries) {
        [s appendFormat:@"  · %@  [%@] %@  %@\n", b.path, b.archs.length ? b.archs : @"?",
         b.encrypted ? @"cryptid≠0" : @"明文", ADXBytesText(b.size)];
    }
    if (ipa.notes.count) {
        [s appendString:@"提示：\n"];
        for (NSString *n in ipa.notes) [s appendFormat:@"  - %@\n", n];
    }
    return s;
}
