//
//  ADXFairPlayJob.m
//  App 扩展层 — FairPlay 用户态砸壳
//
//  流程（与第三方源码的「砸壳」页相互独立，互不影响）：
//    1. 选一个已安装 App，把整个 .app 拷到 fairplayd 认可的暂存目录；
//    2. 扫出所有带 LC_ENCRYPTION_INFO 且 cryptid != 0 的 Mach-O；
//    3. 把 SC_Info 里那份 SINF 按清单 + 每个加密二进制补齐；
//    4. 逐个调用 FairPlayCore 的 fp_decrypt_file_ex()（映射走原始安装路径）；
//    5. 可选改 Info.plist 解除安装限制；
//    6. 打 Payload/… 成 IPA，复查还有没有残留 cryptid。
//
#import "ADXFairPlayJob.h"
#import "ADXInternal.h"
#import "FairPlayCore.h"
#import "SKZipWriter.h"
#import "vfs.h"

#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <sys/stat.h>
#import <unistd.h>

#pragma mark - C 回调

@interface ADXFairPlayJob ()
- (void)emit:(NSString *)line;
- (void)tick:(double)f stage:(NSString *)stage detail:(NSString *)detail;
@end

static void adx_fp_log_cb(void *ctx, const char *msg) {
    ADXFairPlayJob *job = (__bridge ADXFairPlayJob *)ctx;
    if (!job || !msg) return;
    [job emit:@(msg)];
}

#pragma mark - 文件系统小工具

static BOOL adx_path_is_dir(NSString *path) {
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

static BOOL adx_mkdirs(NSString *path) {
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:NULL];
}

static BOOL adx_dir_writable(NSString *dir) {
    NSString *probe = [dir stringByAppendingPathComponent:
                       [NSString stringWithFormat:@".adxprobe-%@", [[NSUUID UUID] UUIDString]]];
    NSData *d = [@"ok" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = [d writeToFile:probe atomically:YES];
    [[NSFileManager defaultManager] removeItemAtPath:probe error:NULL];
    return ok;
}

/// 走内核读文件（vfs_read，绕开沙盒与 POSIX 属主检查）。
/// 应用包里有些文件（典型是 SC_Info/*.supf、*.supp）带额外保护，普通 open()/copyItem
/// 会被沙盒拦成 EPERM —— 第三方砸壳页能拷整个包，是因为它连这类文件也走内核。
static BOOL adx_copy_via_kernel(NSString *src, NSString *dst) {
    if (!vfs_isready()) return NO;
    int64_t size = vfs_filesize(src.fileSystemRepresentation);
    if (size < 0) return NO;
    FILE *out = fopen(dst.fileSystemRepresentation, "wb");
    if (!out) return NO;
    const size_t chunk = 1u << 20;
    void *buf = malloc(chunk);
    if (!buf) { fclose(out); unlink(dst.fileSystemRepresentation); return NO; }
    BOOL ok = YES;
    int64_t off = 0;
    while (off < size) {
        size_t want = (size_t)MIN((int64_t)chunk, size - off);
        int64_t got = vfs_read(src.fileSystemRepresentation, buf, want, (off_t)off);
        if (got <= 0) { ok = NO; break; }
        if (fwrite(buf, 1, (size_t)got, out) != (size_t)got) { ok = NO; break; }
        off += got;
    }
    free(buf);
    fclose(out);
    if (!ok) { unlink(dst.fileSystemRepresentation); return NO; }
    return YES;
}

/// 递归拷贝，保留符号链接；count 统计普通文件数。
/// 单个文件读不到时：先退回内核读取，仍失败就跳过（记进 skipped），不让整个任务失败 ——
/// 应用包里常有一两个受保护文件，因为一个文件放弃整包砸壳没有意义。
static BOOL adx_copy_tree(NSString *src, NSString *dst, NSUInteger *count,
                          NSMutableArray<NSString *> *skipped, NSString **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *e = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:src error:&e];
    if (!attrs) {
        if (err) *err = [NSString stringWithFormat:@"读不到 %@：%@", src.lastPathComponent,
                         e.localizedDescription ?: @"未知错误"];
        return NO;
    }
    NSString *type = attrs[NSFileType];
    if ([type isEqualToString:NSFileTypeDirectory]) {
        if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&e]) {
            if (err) *err = e.localizedDescription;
            return NO;
        }
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:src error:&e];
        if (!items) {
            if (err) *err = [NSString stringWithFormat:@"列目录失败 %@：%@", src,
                             e.localizedDescription ?: @"未知错误"];
            return NO;
        }
        for (NSString *name in items) {
            NSString *s = [src stringByAppendingPathComponent:name];
            NSString *d = [dst stringByAppendingPathComponent:name];
            if (!adx_copy_tree(s, d, count, skipped, err)) return NO;
        }
        return YES;
    }
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
        NSString *target = [fm destinationOfSymbolicLinkAtPath:src error:&e];
        if (!target) {
            if (err) *err = e.localizedDescription;
            return NO;
        }
        [fm removeItemAtPath:dst error:NULL];
        if (![fm createSymbolicLinkAtPath:dst withDestinationPath:target error:&e]) {
            if (err) *err = e.localizedDescription;
            return NO;
        }
        return YES;
    }
    if (![fm copyItemAtPath:src toPath:dst error:&e]) {
        // 沙盒或属主挡住单个文件：改用内核读取重抄一遍，仍不行就跳过。
        if (adx_copy_via_kernel(src, dst)) {
            if (count) (*count)++;
            return YES;
        }
        if (skipped) [skipped addObject:src];
        ADXLogf(@"(fairplay) 跳过读不到的文件：%@（%@）", src.lastPathComponent,
                e.localizedDescription ?: @"未知错误");
        return YES;
    }
    if (count) (*count)++;
    return YES;
}

/// 只看 Mach-O 魔数，避免对每个资源文件都做一次完整解析。
static BOOL adx_file_is_macho(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    uint32_t magic = 0;
    ssize_t n = read(fd, &magic, sizeof magic);
    close(fd);
    if (n != (ssize_t)sizeof magic) return NO;
    return magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == FAT_MAGIC ||
           magic == FAT_CIGAM || magic == MH_MAGIC || magic == MH_CIGAM;
}

#pragma mark - 暂存目录

/// 签名里带的 App Group（fairplayd 只认 App Group 容器，有就优先用）。
static NSString *adx_group_from_profile(void) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    if (!path) return nil;
    NSData *raw = [NSData dataWithContentsOfFile:path];
    if (!raw) return nil;
    NSRange s = [raw rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding]
                         options:0 range:NSMakeRange(0, raw.length)];
    NSRange e = [raw rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding]
                         options:NSDataSearchBackwards range:NSMakeRange(0, raw.length)];
    if (s.location == NSNotFound || e.location == NSNotFound || s.location >= e.location) return nil;
    NSData *plistData = [raw subdataWithRange:NSMakeRange(s.location, NSMaxRange(e) - s.location)];
    id plist = [NSPropertyListSerialization propertyListWithData:plistData
                                                         options:0 format:NULL error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *ents = ((NSDictionary *)plist)[@"Entitlements"];
    if (![ents isKindOfClass:NSDictionary.class]) return nil;
    NSArray *groups = ents[@"com.apple.security.application-groups"];
    if (![groups isKindOfClass:NSArray.class] || !groups.count) return nil;
    return [groups.firstObject isKindOfClass:NSString.class] ? groups.firstObject : nil;
}

#pragma mark - Job

@implementation ADXFairPlayJob {
    BOOL _cancelled;
}

- (void)emit:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    ADXLogBlock block = self.log;
    if (!block) return;
    dispatch_async(dispatch_get_main_queue(), ^{ block(trimmed); });
}

- (void)tick:(double)f stage:(NSString *)stage detail:(NSString *)detail {
    ADXProgressBlock block = self.progress;
    if (!block) return;
    double clamped = MAX(0.0, MIN(1.0, f));
    dispatch_async(dispatch_get_main_queue(), ^{ block(clamped, stage, detail ?: @""); });
}

- (BOOL)isCancelled { return _cancelled; }

- (void)cancel { _cancelled = YES; }

- (void)start {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self run];
    });
}

- (void)fail:(NSString *)message work:(NSString *)work {
    [self emit:[@"❌ " stringByAppendingString:message]];
    if (work.length) [[NSFileManager defaultManager] removeItemAtPath:work error:NULL];
    void (^done)(NSString *, NSString *, NSString *) = self.completion;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil, message, nil); });
}

- (void)run {
    NSDate *started = [NSDate date];
    NSString *appName = self.appName.length ? self.appName : self.bundlePath.lastPathComponent;
    [self emit:[NSString stringWithFormat:@"(fairplay) 开始：%@", appName]];

    if (!adx_path_is_dir(self.bundlePath)) {
        [self fail:[NSString stringWithFormat:@"读不到应用目录：%@\n（需要先在「砸壳」页初始化系统 / 沙盒逃逸）",
                    self.bundlePath] work:nil];
        return;
    }

    // ── 1. 暂存目录 ──────────────────────────────────────────────────────
    [self tick:0.01 stage:@"准备暂存目录" detail:@""];
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *group = adx_group_from_profile();
    if (!group) group = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FairPlayAppGroup"];
    if ([group isKindOfClass:NSString.class] && group.length) {
        NSURL *u = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
        if (u) [roots addObject:u.path];
    }
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length) [roots addObject:docs];
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length) [roots addObject:tmp];

    NSString *stageRoot = nil;
    for (NSString *r in roots) {
        if (!r.length) continue;
        adx_mkdirs(r);
        if (adx_dir_writable(r)) { stageRoot = r; break; }
    }
    if (!stageRoot) {
        [self fail:@"没有可写的暂存目录" work:nil];
        return;
    }
    [self emit:[NSString stringWithFormat:@"暂存目录：%@", stageRoot]];

    NSString *work = [stageRoot stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fpwork-%@", [[NSUUID UUID] UUIDString]]];
    NSString *payload = [work stringByAppendingPathComponent:@"Payload"];
    NSString *bundleName = self.bundlePath.lastPathComponent;
    NSString *stagedApp = [payload stringByAppendingPathComponent:bundleName];
    if (!adx_mkdirs(stagedApp)) {
        [self fail:@"建暂存目录失败" work:work];
        return;
    }

    // ── 2. 拷贝应用包 ────────────────────────────────────────────────────
    [self tick:0.03 stage:@"拷贝应用包" detail:appName];
    NSUInteger copied = 0;
    NSString *copyErr = nil;
    NSMutableArray<NSString *> *skipped = [NSMutableArray array];
    if (!adx_copy_tree(self.bundlePath, stagedApp, &copied, skipped, &copyErr)) {
        [self fail:[NSString stringWithFormat:@"拷贝应用包失败：%@", copyErr ?: @"未知错误"] work:work];
        return;
    }
    [self emit:[NSString stringWithFormat:@"拷贝完成：%lu 个文件%@", (unsigned long)copied,
                skipped.count ? [NSString stringWithFormat:@"（跳过 %lu 个受保护文件）",
                                 (unsigned long)skipped.count] : @""]];
    if (skipped.count) {
        [self emit:[NSString stringWithFormat:@"跳过的文件（沙盒/POSIX 都拒绝，已用内核读兜底仍失败）：%@",
                    [[skipped valueForKeyPath:@"lastPathComponent"] componentsJoinedByString:@", "]]];
    }
    if (_cancelled) { [self fail:@"已取消" work:work]; return; }

    // ── 3. 清点加密的 Mach-O ────────────────────────────────────────────
    [self tick:0.08 stage:@"清点二进制" detail:@""];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *machos = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *encrypted = [NSMutableArray array];
    NSDirectoryEnumerator<NSString *> *en = [fm enumeratorAtPath:stagedApp];
    for (NSString *rel in en) {
        NSString *full = [stagedApp stringByAppendingPathComponent:rel];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
        if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        if ([attrs[NSFileSize] unsignedLongLongValue] < 0x1000) continue;
        if (!adx_file_is_macho(full)) continue;

        fp_slice_t slices[FP_MAX_SLICES];
        int count = 0;
        char err[256] = {0};
        if (fp_parse(full.fileSystemRepresentation, slices, FP_MAX_SLICES, &count, err, sizeof err) != 0)
            continue;

        BOOL needs = NO;
        unsigned long long cipher = 0;
        for (int i = 0; i < count; i++) {
            if (!slices[i].has_enc || slices[i].cryptid == 0) continue;
            needs = YES;
            cipher += slices[i].cryptsize;
        }
        NSDictionary *row = @{ @"rel": rel, @"encrypted": @(needs), @"cipher": @(cipher),
                               @"slices": @(count) };
        [machos addObject:row];
        if (needs) [encrypted addObject:row];
    }
    [self emit:[NSString stringWithFormat:@"Mach-O %lu 个，其中加密 %lu 个",
                (unsigned long)machos.count, (unsigned long)encrypted.count]];

    // 假加密壳：cryptid 还在但 cryptsize 全是 0 —— 没有明文要产出，只清标志。
    if (!encrypted.count) {
        [self emit:@"这个包里没有需要解密的 Mach-O（可能已经是明文包）"];
        [self fail:@"没有可解密的二进制" work:work];
        return;
    }

    // ── 4. 补齐 SINF ────────────────────────────────────────────────────
    [self tick:0.12 stage:@"补齐 SINF" detail:@""];
    NSUInteger sinfCopied = [self replicateSinfInApp:stagedApp machos:machos];
    [self emit:[NSString stringWithFormat:@"SINF 补齐 %lu 个", (unsigned long)sinfCopied]];

    // ── 5. 逐个解密 ─────────────────────────────────────────────────────
    NSUInteger ok = 0, plain = 0, failed = 0, flagsOnly = 0, fakePlain = 0;
    NSMutableArray<NSString *> *failedPaths = [NSMutableArray array];
    NSUInteger total = encrypted.count;
    for (NSUInteger i = 0; i < total; i++) {
        if (_cancelled) { [self fail:@"已取消" work:work]; return; }
        NSDictionary *row = encrypted[i];
        NSString *rel = row[@"rel"];
        double frac = 0.13 + 0.70 * (double)i / (double)MAX(total, (NSUInteger)1);
        [self tick:frac stage:@"正在解密" detail:[NSString stringWithFormat:@"%lu/%lu · %@",
                                                  (unsigned long)(i + 1), (unsigned long)total, rel]];
        [self emit:[NSString stringWithFormat:@"—— %@（密文 %@，%lu 个切片）", rel,
                    ADXBytesText([row[@"cipher"] unsignedLongLongValue]),
                    (unsigned long)[row[@"slices"] unsignedLongValue]]];

        NSString *stagedPath = [stagedApp stringByAppendingPathComponent:rel];
        NSString *origPath = [self.bundlePath stringByAppendingPathComponent:rel];
        BOOL hasOrig = [[NSFileManager defaultManager] fileExistsAtPath:origPath];

        fp_file_stats_t stats;
        memset(&stats, 0, sizeof stats);
        int rc = fp_decrypt_file_ex(stagedPath.fileSystemRepresentation,
                                    (hasOrig ? origPath : stagedPath).fileSystemRepresentation,
                                    stagedPath.fileSystemRepresentation,
                                    adx_fp_log_cb, (__bridge void *)self, &stats);
        if (rc != 0 && rc != 1 && hasOrig) {
            [self emit:@"原始安装路径失败，改用暂存副本重试"];
            fp_file_stats_t retry;
            memset(&retry, 0, sizeof retry);
            int rc2 = fp_decrypt_file_ex(stagedPath.fileSystemRepresentation,
                                         stagedPath.fileSystemRepresentation,
                                         stagedPath.fileSystemRepresentation,
                                         adx_fp_log_cb, (__bridge void *)self, &retry);
            if (rc2 == 0 || rc2 == 1) { rc = rc2; stats = retry; }
        }

        if (rc == 0) {
            if (stats.slices_fake_plain > 0 && stats.slices_ok == 0) {
                fakePlain++;
                [self emit:[NSString stringWithFormat:@"✅ 假加密壳，按明文出包：%@", rel]];
            } else if (stats.slices_ok == 0 && stats.slices_plain > 0) {
                flagsOnly++;
                [self emit:[NSString stringWithFormat:@"○ 仅清标志（cryptsize=0）：%@", rel]];
            } else {
                ok++;
                [self emit:[NSString stringWithFormat:@"✅ 已解密：%@", rel]];
            }
        } else if (rc == 1) {
            plain++;
            [self emit:[NSString stringWithFormat:@"○ 本来就是明文：%@", rel]];
        } else {
            failed++;
            [failedPaths addObject:rel];
            [self emit:[NSString stringWithFormat:@"❌ 解不开：%@", rel]];
        }
    }

    // ── 6. 可选：解除安装限制 ───────────────────────────────────────────
    if (self.relaxInstallRestrictions) {
        [self tick:0.85 stage:@"解除安装限制" detail:@""];
        NSString *msg = [self relaxInstallRestrictionsInApp:stagedApp];
        [self emit:msg];
    }

    // ── 7. 复查残留 ─────────────────────────────────────────────────────
    [self tick:0.88 stage:@"复查产物" detail:@""];
    NSUInteger residue = 0;
    for (NSDictionary *row in encrypted) {
        NSString *rel = row[@"rel"];
        NSString *full = [stagedApp stringByAppendingPathComponent:rel];
        fp_slice_t slices[FP_MAX_SLICES];
        int count = 0;
        char err[256] = {0};
        if (fp_parse(full.fileSystemRepresentation, slices, FP_MAX_SLICES, &count, err, sizeof err) != 0)
            continue;
        for (int i = 0; i < count; i++) {
            if (slices[i].has_enc && slices[i].cryptid != 0) { residue++; break; }
        }
    }

    // ── 8. 打包 ─────────────────────────────────────────────────────────
    [self tick:0.90 stage:@"打包 IPA" detail:@""];
    NSString *outDir = docs.length ? [docs stringByAppendingPathComponent:@"Decrypted"] : work;
    adx_mkdirs(outDir);
    NSString *stem = [appName stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (!stem.length) stem = bundleName.stringByDeletingPathExtension;
    NSString *ipa = [outDir stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"ipa"]];

    __weak typeof(self) weakSelf = self;
    NSString *zipErr = [SKZipWriter zipDirectory:payload
                                           toPath:ipa
                                         progress:^(NSString *entry, NSUInteger done, NSUInteger tot) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        double f = 0.90 + 0.09 * (tot ? (double)done / (double)tot : 0.0);
        [strongSelf tick:f stage:@"打包 IPA" detail:entry.lastPathComponent];
    }];
    if (zipErr.length) {
        [self fail:[NSString stringWithFormat:@"打包失败：%@", zipErr] work:work];
        return;
    }

    NSDictionary *ipattrs = [NSFileManager.defaultManager attributesOfItemAtPath:ipa error:NULL];
    unsigned long long size = [ipattrs[NSFileSize] unsignedLongLongValue];
    if (!size) {
        [self fail:@"打包出来的 IPA 是空的" work:work];
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:work error:NULL];

    double secs = -[started timeIntervalSinceNow];
    NSString *summary = [NSString stringWithFormat:
                         @"%@\n解密 %lu · 明文 %lu · 假壳 %lu · 仅清标志 %lu · 失败 %lu%@\n产物 %@（%@）· 用时 %.0f 秒",
                         appName, (unsigned long)ok, (unsigned long)plain, (unsigned long)fakePlain,
                         (unsigned long)flagsOnly, (unsigned long)failed,
                         residue ? [NSString stringWithFormat:@" · 残留 %lu", (unsigned long)residue] : @"",
                         ipa.lastPathComponent, ADXBytesText(size), secs];
    [self emit:@"==== 完成 ===="];
    [self emit:summary];
    if (failedPaths.count)
        [self emit:[NSString stringWithFormat:@"失败清单：%@", [failedPaths componentsJoinedByString:@", "]]];

    [self tick:1.0 stage:@"完成" detail:ipa.lastPathComponent];
    void (^done)(NSString *, NSString *, NSString *) = self.completion;
    if (done) {
        NSString *finalSummary = summary;
        dispatch_async(dispatch_get_main_queue(), ^{ done(ipa, nil, finalSummary); });
    }
}

#pragma mark - SINF

- (NSUInteger)replicateSinfInApp:(NSString *)appDir machos:(NSArray<NSDictionary *> *)machos {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *manifestPath = [appDir stringByAppendingPathComponent:@"SC_Info/Manifest.plist"];
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    if (![manifest isKindOfClass:NSDictionary.class]) {
        [self emit:@"没有 SC_Info/Manifest.plist，跳过 SINF 复制"];
        return 0;
    }
    NSArray *declared = manifest[@"SinfPaths"];
    if (![declared isKindOfClass:NSArray.class] || !declared.count) {
        [self emit:@"Manifest 里没有 SinfPaths"];
        return 0;
    }
    NSString *first = [declared.firstObject isKindOfClass:NSString.class] ? declared.firstObject : nil;
    if (!first.length) return 0;
    NSString *source = [appDir stringByAppendingPathComponent:first];
    if (![fm fileExistsAtPath:source]) {
        [self emit:[NSString stringWithFormat:@"主 SINF 不可读：%@", first]];
        return 0;
    }

    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    NSArray *repl = manifest[@"SinfReplicationPaths"];
    if ([repl isKindOfClass:NSArray.class]) {
        for (id t in repl) if ([t isKindOfClass:NSString.class]) [targets addObject:t];
    }
    for (NSDictionary *row in machos) {
        if (![row[@"encrypted"] boolValue]) continue;
        NSString *rel = row[@"rel"];
        NSString *dir = rel.stringByDeletingLastPathComponent;
        NSString *name = rel.lastPathComponent;
        NSString *target = dir.length ? [dir stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"SC_Info/%@.sinf", name]]
                                      : [NSString stringWithFormat:@"SC_Info/%@.sinf", name];
        [targets addObject:target];
    }

    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger copied = 0;
    for (NSString *t in targets) {
        if (![t.lowercaseString hasSuffix:@".sinf"]) continue;
        if ([seen containsObject:t]) continue;
        [seen addObject:t];
        NSString *dst = [appDir stringByAppendingPathComponent:t];
        if ([fm fileExistsAtPath:dst]) continue;
        adx_mkdirs(dst.stringByDeletingLastPathComponent);
        if ([fm copyItemAtPath:source toPath:dst error:NULL]) copied++;
    }
    return copied;
}

#pragma mark - 安装限制

- (NSString *)relaxInstallRestrictionsInApp:(NSString *)appDir {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *targets = [NSMutableArray arrayWithObject:
                                           [appDir stringByAppendingPathComponent:@"Info.plist"]];
    NSString *plugins = [appDir stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *p in [fm contentsOfDirectoryAtPath:plugins error:NULL]) {
        if (![p hasSuffix:@".appex"]) continue;
        [targets addObject:[[plugins stringByAppendingPathComponent:p]
                            stringByAppendingPathComponent:@"Info.plist"]];
    }
    NSUInteger patched = 0, stripped = 0;
    for (NSString *path in targets) {
        if (![fm fileExistsAtPath:path]) continue;
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!dict) continue;
        dict[@"MinimumOSVersion"] = @"10.0";
        if (dict[@"UIRequiredDeviceCapabilities"]) { [dict removeObjectForKey:@"UIRequiredDeviceCapabilities"]; stripped++; }
        if (dict[@"UISupportedDevices"]) { [dict removeObjectForKey:@"UISupportedDevices"]; stripped++; }
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0 error:NULL];
        if (data && [data writeToFile:path atomically:YES]) patched++;
    }
    return [NSString stringWithFormat:@"安装限制：改了 %lu 个 Info.plist（MinimumOSVersion → 10.0，去掉 %lu 项设备限制）",
            (unsigned long)patched, (unsigned long)stripped];
}

@end