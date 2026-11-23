#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import "FileManager.h"
#import "SKLoc.h"
#import "SKFMPlistEditor.h"
#import "SKFMTags.h"
#import "SKAppOwn.h"
#import "SKSandboxKeeper.h"
#import "SKPermsEditor.h"
#import "SKFileWriter.h"
#import "apfs.h"
#import "SKKernelLock.h"
#import "SKPathPolicy.h"
#import "darksword.h"
#import <sys/stat.h>
#import <sys/types.h>
#import <dirent.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#include <limits.h>
#include <string.h>
#include <zlib.h>
#include <time.h>
#include <utime.h>

#pragma mark - NSString category helpers

static inline const char *utf8Str(id obj) {
    return [(NSString *)obj UTF8String];
}

static inline NSString *TrimStr(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static inline void HapticMedium(void) {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [g prepare];
        [g impactOccurred];
    }
}
static inline void HapticLight(void) {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g prepare];
        [g impactOccurred];
    }
}
static inline void HapticSelect(void) {
    if (@available(iOS 10.0, *)) {
        UISelectionFeedbackGenerator *g = [[UISelectionFeedbackGenerator alloc] init];
        [g prepare];
        [g selectionChanged];
    }
}

static inline unsigned scanOctal(NSString *s) {
    unsigned val = 0;
    const char *p = s.UTF8String;
    while (*p) {
        if (*p < '0' || *p > '7') break;
        val = val * 8 + (*p - '0');
        p++;
    }
    return val;
}

#pragma mark - Global Clipboard (lara-style santanderclip)

@interface ClipboardItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isCut; // YES = move, NO = copy
@end
@implementation ClipboardItem
@end

static ClipboardItem *gClipboard = nil;

#pragma mark - ZIP helpers (translated from lara zipmgr.swift)

static const UInt32 zipEOCDSig  = 0x06054b50;
static const UInt32 zipCDSig    = 0x02014b50;
static const UInt32 zipLFHSig   = 0x04034b50;

static void zipWriteLE16(UInt16 val, NSMutableData *d) {
    [d appendBytes:&val length:2];
}
static void zipWriteLE32(UInt32 val, NSMutableData *d) {
    [d appendBytes:&val length:4];
}

static UInt32 zipCrc32Table[256];
static dispatch_once_t zipCrcOnce;
static void zipInitCrcTable(void) {
    dispatch_once(&zipCrcOnce, ^{
        for (UInt32 n = 0; n < 256; n++) {
            UInt32 c = n;
            for (int k = 0; k < 8; k++) {
                c = (c & 1) ? (0xedb88320 ^ (c >> 1)) : (c >> 1);
            }
            zipCrc32Table[n] = c;
        }
    });
}
static UInt32 zipCrc32(NSData *data) {
    zipInitCrcTable();
    UInt32 c = 0xffffffff;
    const UInt8 *p = (const UInt8 *)data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        c = zipCrc32Table[(c ^ p[i]) & 0xff] ^ (c >> 8);
    }
    return c ^ 0xffffffff;
}

static BOOL recursiveZipDir(NSString *srcDir, NSString *relativeBase,
                            NSMutableArray<NSDictionary *> *fileEntries,
                            NSMutableArray<NSString *> *dirEntries) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray *names = [fm contentsOfDirectoryAtPath:srcDir error:&err];
    if (!names) return NO;

    for (NSString *name in names) {
        NSString *full = [srcDir stringByAppendingPathComponent:name];
        NSString *rel = relativeBase.length ? [relativeBase stringByAppendingPathComponent:name] : name;

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;

        if (isDir) {
            [dirEntries addObject:[rel stringByAppendingString:@"/"]];
            recursiveZipDir(full, rel, fileEntries, dirEntries);
        } else {
            NSData *data = [NSData dataWithContentsOfFile:full
                                                  options:NSDataReadingMappedIfSafe
                                                    error:nil];
            if (!data) data = [NSData data];
            UInt32 crc = zipCrc32(data);
            [fileEntries addObject:@{
                @"name": rel,
                @"data": data,
                @"crc": @(crc)
            }];
        }
    }
    return YES;
}

// Returns nil on success, else error message
NSString *zipPathTo(NSString *srcPath, NSString *dstPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:srcPath isDirectory:&isDir]) {
        return SKLoc(@"fm.err.srcMissing");
    }

    NSMutableArray<NSDictionary *> *fileEntries = [NSMutableArray array];
    NSMutableArray<NSString *> *dirEntries = [NSMutableArray array];

    if (isDir) {
        // Add the root dir entry
        NSString *rootName = srcPath.lastPathComponent;
        [dirEntries addObject:[rootName stringByAppendingString:@"/"]];
        if (!recursiveZipDir(srcPath, rootName, fileEntries, dirEntries)) {
            return SKLoc(@"fm.err.enumDir");
        }
    } else {
        NSData *data = [NSData dataWithContentsOfFile:srcPath
                                              options:NSDataReadingMappedIfSafe
                                                error:nil];
        if (!data) return SKLoc(@"fm.err.readFile");
        UInt32 crc = zipCrc32(data);
        [fileEntries addObject:@{
            @"name": srcPath.lastPathComponent,
            @"data": data,
            @"crc": @(crc)
        }];
    }

    [fm createFileAtPath:dstPath contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:dstPath];
    if (!fh) return SKLoc(@"fm.err.createZip");

    NSMutableArray<NSNumber *> *localOffsets = [NSMutableArray array];
    NSMutableArray<NSData *> *cdEntries = [NSMutableArray array];
    UInt16 compressionMethod = 0; // store only for compatibility

    @autoreleasepool {
        for (NSDictionary *entry in fileEntries) {
            NSString *name = entry[@"name"];
            NSData *data = entry[@"data"];
            UInt32 crc = [entry[@"crc"] unsignedIntValue];
            NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
            UInt16 nameLen = (UInt16)nameData.length;
            UInt32 offset = (UInt32)fh.offsetInFile;

            NSMutableData *lfh = [NSMutableData data];
            zipWriteLE32(zipLFHSig, lfh);
            zipWriteLE16(20, lfh);          // version needed
            zipWriteLE16(0x0800, lfh);       // flags = UTF8 name
            zipWriteLE16(compressionMethod, lfh);
            zipWriteLE16(0, lfh);            // mod time
            zipWriteLE16(0, lfh);            // mod date
            zipWriteLE32(crc, lfh);
            zipWriteLE32((UInt32)data.length, lfh);
            zipWriteLE32((UInt32)data.length, lfh);
            zipWriteLE16(nameLen, lfh);
            zipWriteLE16(0, lfh);            // extra len
            [fh writeData:lfh];
            [fh writeData:nameData];
            if (data.length) [fh writeData:data];

            NSMutableData *cd = [NSMutableData data];
            zipWriteLE32(zipCDSig, cd);
            zipWriteLE16(20, cd);            // version made by
            zipWriteLE16(20, cd);            // version needed
            zipWriteLE16(0x0800, cd);        // flags = UTF8
            zipWriteLE16(compressionMethod, cd);
            zipWriteLE16(0, cd);             // mod time
            zipWriteLE16(0, cd);             // mod date
            zipWriteLE32(crc, cd);
            zipWriteLE32((UInt32)data.length, cd);
            zipWriteLE32((UInt32)data.length, cd);
            zipWriteLE16(nameLen, cd);
            zipWriteLE16(0, cd);             // extra
            zipWriteLE16(0, cd);             // comment
            zipWriteLE16(0, cd);             // disk number start
            zipWriteLE16(0, cd);             // internal attr
            // Preserve the real mode. A hardcoded 0644 stripped the executable
            // bit off binaries, which breaks sideloading an .ipa.
            {
                struct stat st;
                mode_t mode = 0100644;
                // `name` is relative to the zip root, and srcPath's parent is
                // that root — appending it to srcPath would duplicate the
                // leading folder and the stat would always fail.
                NSString *fullPath = [[srcPath stringByDeletingLastPathComponent]
                                      stringByAppendingPathComponent:name];
                if (stat(fullPath.fileSystemRepresentation, &st) == 0) {
                    mode = st.st_mode & 07777;
                    mode |= 0100000;   // S_IFREG
                }
                // External attributes: the high 16 bits hold the Unix mode,
                // the low 16 bits the DOS attributes. Getting this order wrong
                // (e.g. OR-ing the mode into the low half) produces a malformed
                // central directory that strict ZIP readers reject outright.
                zipWriteLE32(((UInt32)mode << 16), cd);
            }
            zipWriteLE32(offset, cd);
            [cd appendData:nameData];

            [localOffsets addObject:@(offset)];
            [cdEntries addObject:cd];
        }

        for (NSString *dirName in dirEntries) {
            NSData *nameData = [dirName dataUsingEncoding:NSUTF8StringEncoding];
            UInt16 nameLen = (UInt16)nameData.length;
            UInt32 offset = (UInt32)fh.offsetInFile;

            NSMutableData *lfh = [NSMutableData data];
            zipWriteLE32(zipLFHSig, lfh);
            zipWriteLE16(20, lfh);
            zipWriteLE16(0x0800, lfh);
            zipWriteLE16(0, lfh);
            zipWriteLE16(0, lfh);
            zipWriteLE16(0, lfh);
            zipWriteLE32(0, lfh);
            zipWriteLE32(0, lfh);
            zipWriteLE32(0, lfh);
            zipWriteLE16(nameLen, lfh);
            zipWriteLE16(0, lfh);
            [fh writeData:lfh];
            [fh writeData:nameData];

            NSMutableData *cd = [NSMutableData data];
            zipWriteLE32(zipCDSig, cd);
            zipWriteLE16(20, cd);
            zipWriteLE16(20, cd);
            zipWriteLE16(0x0800, cd);
            zipWriteLE16(0, cd);
            zipWriteLE16(0, cd);
            zipWriteLE16(0, cd);
            zipWriteLE32(0, cd);
            zipWriteLE32(0, cd);
            zipWriteLE32(0, cd);
            zipWriteLE16(nameLen, cd);
            zipWriteLE16(0, cd);
            zipWriteLE16(0, cd);
            zipWriteLE16(0, cd);
            zipWriteLE16(0, cd);
            zipWriteLE16(0, cd);
            zipWriteLE32(0x41ED0000, cd); // directory external attr
            zipWriteLE32(offset, cd);
            [cd appendData:nameData];
            [cdEntries addObject:cd];
        }
    }

    UInt32 cdOffset = (UInt32)fh.offsetInFile;
    UInt32 cdSize = 0;
    for (NSData *cd in cdEntries) {
        [fh writeData:cd];
        cdSize += (UInt32)cd.length;
    }

    UInt16 totalEntries = (UInt16)(fileEntries.count + dirEntries.count);
    NSMutableData *eocd = [NSMutableData data];
    zipWriteLE32(zipEOCDSig, eocd);
    zipWriteLE16(0, eocd);
    zipWriteLE16(0, eocd);
    zipWriteLE16(totalEntries, eocd);
    zipWriteLE16(totalEntries, eocd);
    zipWriteLE32(cdSize, eocd);
    zipWriteLE32(cdOffset, eocd);
    zipWriteLE16(0, eocd);
    [fh writeData:eocd];
    [fh closeFile];
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Recovery from a failed file operation
// ─────────────────────────────────────────────────────────────────────────────
//
// Two completely unrelated problems both come back as "permission denied":
//
//   EPERM   the sandbox policy was re-derived from the on-disk profile and our
//           edit is gone. The file is fine; our permission to touch it is not.
//           Re-applying the escape restores it, without re-running the exploit.
//   EACCES  the parent directory is not ours, so it cannot be written to.
//           Fixing it means taking ownership of that directory.
//
// Reporting strerror(errno) tells the operator neither, so the operation is
// retried once after repairing both, and if it still fails the two states are
// reported separately.

// Defined below; declared here because the recovery path above it calls it.
static int recursive_delete_c(const char *path);

static int SKDeleteWithRecovery(NSString *path, BOOL isDir) {
    int r = isDir ? recursive_delete_c(utf8Str(path)) : unlink(utf8Str(path));
    if (r == 0) return 0;

    int e = errno;
    if (e != EACCES && e != EPERM) return r;

    // Nothing is repaired here. A failed delete is reported as a failed delete.
    //
    // This used to re-apply the sandbox policy and then rewrite the container's
    // ownership — a kernel APFS write that recurses over the whole tree — just
    // because an unlink() returned EACCES. One file operation is not a licence to
    // re-own an entire container.
    errno = 0;
    return isDir ? recursive_delete_c(utf8Str(path)) : unlink(utf8Str(path));
}

static NSString *SKFailureDetail(NSString *path, int err) {
    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"errno=%d (%s)\n", err, strerror(err)];

    BOOL escaped = [SKSandboxKeeper hasPrivilegedWriteAccess];
    [m appendFormat:@"sandbox_write_access=%d\n", escaped ? 1 : 0];
    [m appendFormat:@"ds_is_ready=%d\n", ds_is_ready() ? 1 : 0];

    NSString *parent = [path stringByDeletingLastPathComponent];
    struct stat psb;
    if (parent.length && lstat(utf8Str(parent), &psb) == 0) {
        [m appendFormat:@"parent=%s uid=%u gid=%u mode=%04o\n",
            utf8Str(parent), psb.st_uid, psb.st_gid, psb.st_mode & 07777];
        if (psb.st_uid != 501) {
            [m appendFormat:@"dac_deny: parent owner is not 501; unlink() requires "
                            "write on the PARENT directory\n"];
        }
    } else {
        [m appendFormat:@"lstat(%s) failed: %s\n", utf8Str(parent), strerror(errno)];
    }
    return m;
}

#pragma mark - File operations

static int recursive_delete_c(const char *path) {
    DIR *dir = opendir(path);
    if (!dir) return unlink(path);
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        char child[PATH_MAX];
        snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
        struct stat st;
        if (lstat(child, &st) == 0) {
            if (S_ISDIR(st.st_mode)) recursive_delete_c(child);
            else unlink(child);
        }
    }
    closedir(dir);
    return rmdir(path);
}

static NSString *uniquePath(NSString *base) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:base]) return base;
    NSString *dir = [base stringByDeletingLastPathComponent];
    NSString *file = base.lastPathComponent;
    NSString *ext = file.pathExtension;
    NSString *stem = ext.length ? [file stringByDeletingPathExtension] : file;
    for (int i = 1; ; i++) {
        NSString *suffix = i == 1 ? @" copy" : [NSString stringWithFormat:@" copy %d", i];
        NSString *name = ext.length ? [NSString stringWithFormat:@"%@%@.%@", stem, suffix, ext]
                                    : [NSString stringWithFormat:@"%@%@", stem, suffix];
        NSString *cand = [dir stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:cand]) return cand;
    }
}

// 用内核直接改 inode 的属主/权限，绕开 vnode_authorize。
//
// .app 里的东西属主是 root、目录是 0755，所以 mobile(501) 连"在目录里建文件"
// 都做不到 —— 这跟沙盒无关，是 Unix DAC。apfs_own/apfs_mod 直接写 APFS 的
// inode 字段，不经过授权检查，等价于 Filza 的"取得写权限"。
// 只在普通写已经失败之后才调用，不改变开箱状态。
static BOOL SKKernelTakeOwnership(NSString *path) {
    if (!ds_is_ready() || path.length == 0) return NO;

    // 收口：这是所有"内核改属主"的唯一入口，所以规则放在这里。
    // 以前它只挡了 "/"，文本/plist 编辑器的保存可以从 /Applications 下的
    // 系统 app 里进来，把系统文件的属主改成 mobile。
    if (!SKPathAllowsModify(path)) {
        printf("[fm] 拒绝内核改属主（%s 不在 /var 下）: %s\n",
               "只读区", path.UTF8String);
        return NO;
    }

    const char *p = utf8Str(path);
    struct stat st;
    if (stat(p, &st) != 0) return NO;

    // 已经是我们且 owner 可写 —— 什么都不用做。
    // 整树 chown 之后这一条是常态，于是这里零内核写。
    if (st.st_uid == 501 && (st.st_mode & S_IWUSR)) return YES;

    // 约定：调用方持 SKKernelLock。apfs_* 内部不加锁（NSLock 非递归）。
    // 整段包 @try —— ds_kwrite* 走 set_target_kaddr，地址不合规会抛
    // NSException；不接住就是直接闪退。@finally 保证锁一定被释放，
    // 否则后面所有内核操作都会永久卡死。
    BOOL ok = NO;
    [SKKernelLock() lock];
    @try {
        apfs_own(p, 501, 501);
        // 带上类型位，否则会把 S_IFDIR/S_IFREG 清零
        apfs_mod(p, (mode_t)((st.st_mode & 0xFFFF) | S_IRUSR | S_IWUSR));
        struct stat after;
        ok = (stat(p, &after) == 0) && after.st_uid == 501;
    } @catch (NSException *ex) {
        printf("[fm] 内核取得写权限抛异常 %s: %s\n", path.UTF8String, ex.reason.UTF8String);
        ok = NO;
    } @finally {
        [SKKernelLock() unlock];
    }

    printf("[fm] 内核取得写权限 %s: %s (uid %u->501 mode %04o->%04o)\n", path.UTF8String,
           ok ? "成功" : "失败", (unsigned)st.st_uid, st.st_mode & 07777,
           (st.st_mode & 07777) | 0600);
    return ok;
}

// 目录不可写时，让父目录可以被我们写 —— 建文件/粘贴/改名都依赖这个。
static BOOL SKKernelOwnParent(NSString *path) {
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (parent.length == 0) return NO;
    return SKKernelTakeOwnership(parent);
}

static BOOL clearImmutableFlag(NSString *path) {
    // Clear immutable flag on iOS 16+ for delete/chmod/chown operations
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    [fm setAttributes:@{NSFileImmutable: @(NO)} ofItemAtPath:path error:&err];
    return YES; // ignore errors; some files don't expose this flag
}

static BOOL copyItem(NSString *src, NSString *dst) {
    NSFileManager *fm = [NSFileManager defaultManager];
    clearImmutableFlag(dst);
    NSError *err = nil;
    return [fm copyItemAtPath:src toPath:dst error:&err];
}

static BOOL moveItem(NSString *src, NSString *dst) {
    NSFileManager *fm = [NSFileManager defaultManager];
    clearImmutableFlag(dst);
    NSError *err = nil;
    if ([fm moveItemAtPath:src toPath:dst error:&err]) return YES;
    // Fallback to copy+delete on cross-device failure
    if (copyItem(src, dst)) {
        if (recursive_delete_c(src.UTF8String) == 0) return YES;
    }
    return NO;
}


#pragma mark - Text Editor (browse / edit / save)

@interface FMTextEditorViewController : UIViewController <UITextViewDelegate>
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, assign) BOOL modified;
@end
@implementation FMTextEditorViewController

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) { _filePath = [path copy]; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.filePath.lastPathComponent;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                                                             target:self
                                                                                             action:@selector(saveTapped)];

    // TextView
    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.delegate = self;
    self.textView.font = [UIFont fontWithName:@"Menlo-Regular" size:14];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.text = @"";
    self.textView.editable = YES;
    [self.view addSubview:self.textView];

    // Load content
    NSData *data = [NSData dataWithContentsOfFile:self.filePath];
    if (data) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        if (text) {
            self.textView.text = text;
            self.modified = NO;
        } else {
            self.textView.text = SKLoc(@"fm.binaryFile");
            self.textView.editable = NO;
        }
    } else {
        self.textView.text = SKLoc(@"fm.cannotRead");
        self.textView.editable = NO;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.textView.frame = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
}

- (void)textViewDidChange:(UITextView *)textView {
    self.modified = YES;
}

- (void)saveTapped {
    if (!self.modified) return;
    // 只读区（/var 之外）只能看。这条以前只写在文件管理器菜单里，
    // 编辑器保存是绕过它的。
    if (!SKPathAllowsModify(self.filePath)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.readonly")
                                                                  message:self.filePath
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.ok")
                                             style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSError *err = nil;
    BOOL ok = [self.textView.text writeToFile:self.filePath atomically:YES encoding:NSUTF8StringEncoding error:&err];

    // 第一步失败常见原因是不可变标志位（.app 里的文件常带），先清掉再试一次。
    if (!ok) {
        clearImmutableFlag(self.filePath);
        ok = [self.textView.text writeToFile:self.filePath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    }

    // 还是失败就说明是 DAC：沙盒放行了，但 Unix 权限没放行（.app 内部）。
    // 先用内核把属主改成自己，再走一次普通写 —— 这条路能处理"新内容更长"。
    if (!ok && SKKernelTakeOwnership(self.filePath)) {
        ok = [self.textView.text writeToFile:self.filePath atomically:YES
                                    encoding:NSUTF8StringEncoding error:&err];
    }

    // 还不行才退到 SKFileWriter 的内核映射路径（只能覆盖、不能扩容）。
    NSData *payload = [self.textView.text dataUsingEncoding:NSUTF8StringEncoding];
    if (!ok && [SKFileWriter kernelWriteAvailable]) {
        NSError *kerr = nil;
        SKWriteMethod m = [SKFileWriter replacePath:self.filePath withData:payload error:&kerr];
        if (m != SKWriteMethodFailed) {
            ok = YES;
            printf("[fm] 保存 %s: %s\n", self.filePath.UTF8String, [SKFileWriter describeMethod:m].UTF8String);
        } else {
            // 内核路径不能扩容 —— 新内容比原文件长时它必然失败，说清楚而不是只报"失败"
            err = kerr ?: [NSError errorWithDomain:@"blade" code:1 userInfo:@{
                NSLocalizedDescriptionKey: SKLoc(@"fm.write.shrinkOnly") }];
        }
    }
    if (ok) {
        // 写盘后逃逸多半已经被内核冲掉了，立刻补回来。
        if (ds_is_ready()) [SKSandboxKeeper restoreIfLost:@"保存文本"];
        self.modified = NO;
        self.navigationItem.rightBarButtonItem.enabled = YES;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.saved") message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.saveFailed") message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

#pragma mark - Image Viewer (scroll + zoom)

@interface FMImageViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIImageView *imageView;
@end
@implementation FMImageViewController

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) { _filePath = [path copy]; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = self.filePath.lastPathComponent;

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.delegate = self;
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 6.0;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.backgroundColor = [UIColor blackColor];
    [self.view addSubview:self.scrollView];

    UIImage *img = [UIImage imageWithContentsOfFile:self.filePath];
    self.imageView = [[UIImageView alloc] initWithImage:img];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.scrollView addSubview:self.imageView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.scrollView.frame = self.view.bounds;
    if (self.imageView.image) {
        CGSize isize = self.imageView.image.size;
        CGSize vsize = self.view.bounds.size;
        CGFloat scale = MIN(vsize.width / isize.width, vsize.height / isize.height);
        scale = MIN(scale, 1.0);
        self.scrollView.minimumZoomScale = scale;
        self.scrollView.zoomScale = scale;
        self.imageView.frame = CGRectMake(0, 0, isize.width * scale, isize.height * scale);
        self.imageView.center = CGPointMake(vsize.width/2, vsize.height/2);
    }
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}
@end


#pragma mark - String category

@implementation NSString (FileManagerTrim)
@end

#pragma mark - ZIP Unzip (store + deflate)

static int mkdir_p(const char *path) {
    NSMutableArray<NSString *> *comps = [NSMutableArray array];
    NSString *p = [NSString stringWithUTF8String:path];
    while (p.length > 0 && ![p isEqualToString:@"/"]) {
        [comps insertObject:p.lastPathComponent atIndex:0];
        p = [p stringByDeletingLastPathComponent];
    }
    NSString *cur = @"";
    for (NSString *c in comps) {
        cur = [cur stringByAppendingPathComponent:c];
        if (cur.length == 0) cur = @"/";
        struct stat st;
        if (stat(cur.UTF8String, &st) != 0) {
            if (mkdir(cur.UTF8String, 0755) != 0 && errno != EEXIST) return -1;
        }
    }
    return 0;
}

static NSData *inflateData(NSData *compressed, NSUInteger uncompressedSize) {
    if (!compressed || compressed.length == 0) {
        if (uncompressedSize == 0) return [NSData data];
        return nil;
    }
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // -15: raw deflate (no zlib header) - ZIP uses raw deflate
    int ret = inflateInit2(&strm, -MAX_WBITS);
    if (ret != Z_OK) return nil;

    NSMutableData *out = [NSMutableData dataWithLength:MAX(uncompressedSize, compressed.length * 2)];
    strm.next_in = (Bytef *)compressed.bytes;
    strm.avail_in = (unsigned)compressed.length;
    strm.next_out = (Bytef *)out.mutableBytes;
    strm.avail_out = (unsigned)out.length;

    while (1) {
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret == Z_STREAM_END) break;
        if (ret == Z_OK) {
            if (strm.avail_out == 0) {
                NSUInteger used = out.length;
                out.length = used * 2;
                strm.next_out = (Bytef *)((char *)out.mutableBytes + used);
                strm.avail_out = (unsigned)(out.length - used);
            }
            continue;
        }
        inflateEnd(&strm);
        return nil;
    }
    out.length = strm.total_out;
    inflateEnd(&strm);
    return out;
}

// Returns nil on success, else error string
static NSString *unzipFileTo(NSString *zipPath, NSString *dstDir) {
    NSData *zd = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:nil];
    if (!zd) return SKLoc(@"fm.err.openZip");
    const UInt8 *bytes = (const UInt8 *)zd.bytes;
    NSUInteger len = zd.length;
    if (len < 22) return SKLoc(@"fm.err.zipSmall");

    // Find EOCD by scanning backwards
    NSInteger eocdOff = -1;
    NSInteger scanStart = (NSInteger)MAX(0, (NSInteger)len - 65557);
    for (NSInteger i = (NSInteger)len - 22; i >= scanStart; i--) {
        UInt32 sig = OSReadLittleInt32(bytes, i);
        if (sig == zipEOCDSig) { eocdOff = i; break; }
    }
    if (eocdOff < 0) return SKLoc(@"fm.err.zipNoEocd");
    UInt16 cdEntries = OSReadLittleInt16(bytes, eocdOff + 10);
    UInt32 cdSize = OSReadLittleInt32(bytes, eocdOff + 12);
    UInt32 cdOff = OSReadLittleInt32(bytes, eocdOff + 16);
    if (cdOff >= len || cdOff + cdSize > len) return SKLoc(@"fm.err.zipCdRange");

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:&err]) {
        return [NSString stringWithFormat:SKLoc(@"fm.err.mkdir"), err.localizedDescription];
    }

    NSUInteger p = cdOff;
    for (UInt16 i = 0; i < cdEntries && p + 46 <= len; i++) {
        UInt32 sig = OSReadLittleInt32(bytes, p);
        if (sig != zipCDSig) break;
        UInt16 nameLen = OSReadLittleInt16(bytes, p + 28);
        UInt16 extraLen = OSReadLittleInt16(bytes, p + 30);
        UInt16 commentLen = OSReadLittleInt16(bytes, p + 32);
        UInt16 method = OSReadLittleInt16(bytes, p + 10);
        UInt32 compSize = OSReadLittleInt32(bytes, p + 20);
        UInt32 uncompSize = OSReadLittleInt32(bytes, p + 24);
        UInt32 localHeaderOffset = OSReadLittleInt32(bytes, p + 42);
        if (p + 46 + nameLen > len) break;
        NSString *name = [[NSString alloc] initWithBytes:bytes + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithBytes:bytes + p + 46 length:nameLen encoding:NSASCIIStringEncoding];
        p += 46 + nameLen + extraLen + commentLen;

        BOOL isDir = NO;
        if ([name hasSuffix:@"/"] || [name hasSuffix:@"\\"]) {
            isDir = YES;
            name = [name substringToIndex:name.length - 1];
        }
        NSString *fullDst = [dstDir stringByAppendingPathComponent:name];

        if (isDir) {
            mkdir_p(fullDst.UTF8String);
            continue;
        }
        mkdir_p([fullDst stringByDeletingLastPathComponent].UTF8String);

        // Parse local file header to get past name/extra
        if (localHeaderOffset + 30 > len) continue;
        UInt32 lfhSig = OSReadLittleInt32(bytes, localHeaderOffset);
        if (lfhSig != zipLFHSig) continue;
        UInt16 lfhNameLen = OSReadLittleInt16(bytes, localHeaderOffset + 26);
        UInt16 lfhExtraLen = OSReadLittleInt16(bytes, localHeaderOffset + 28);
        NSUInteger dataStart = localHeaderOffset + 30 + lfhNameLen + lfhExtraLen;
        if (dataStart + compSize > len) continue;

        NSData *decoded = nil;
        if (method == 0) { // stored
            decoded = [NSData dataWithBytes:bytes + dataStart length:compSize];
        } else if (method == 8) { // deflated
            NSData *comp = [NSData dataWithBytes:bytes + dataStart length:compSize];
            decoded = inflateData(comp, uncompSize);
        } else {
            continue; // unsupported compression
        }
        if (!decoded) continue;
        [decoded writeToFile:fullDst atomically:NO];
    }
    return nil;
}


#pragma mark - FileManagerViewController

@class FMTextEditorViewController;
@class FMImageViewController;

@interface FileManagerViewController () <UITableViewDelegate, UITableViewDataSource, UISearchResultsUpdating>
@property (nonatomic, strong, readwrite) NSString *currentPath;
@property (nonatomic, strong, readwrite) UITableView *tableView;
@property (nonatomic, strong, readwrite) NSMutableArray *fileList;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPress;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSMutableArray *filteredList;
@property (nonatomic, assign) BOOL isSearching;
@property (nonatomic, strong) UIToolbar *toolbar;
@property (nonatomic, strong) UIView *bottomFillView;
// 「上一级」的边界：入口路径。默认不许越出它，避免从 /var 一路跳到 /。
// App 管理器跳进来的那种场景把 allowEscapeAboveRoot 打开，才允许继续往上。
@property (nonatomic, copy) NSString *navRoot;   // allowEscapeAboveRoot 已在 .h 公开
- (void)extractZip:(NSDictionary *)item;
- (void)openFileViewerForItem:(NSDictionary *)item;
@end

@implementation FileManagerViewController

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _currentPath = [path copy];
        _navRoot = [path copy];
        _fileList = [NSMutableArray array];
        _filteredList = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self setupNavUI];
    [self setupTable];
    [self setupToolbar];
    [self setupSearch];
    [self loadDirectory];

    self.longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.longPress.minimumPressDuration = 0.4;
    [self.tableView addGestureRecognizer:self.longPress];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:YES];
    [self updateToolbarItems];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat searchBarSpace = 20.0; // 搜索栏与列表分离
    CGFloat tableTop = safe.top + searchBarSpace;
    // 底栏下移10px：原上移35px -> 现上移25px
    CGFloat toolbarRaise = -12;
    CGFloat toolbarY = bounds.size.height - 44 - safe.bottom - toolbarRaise;
    // tableView底部止于toolbar顶部（toolbar下方空白单独处理）
    CGFloat tableBottom = bounds.size.height - toolbarY;

    if (@available(iOS 11.0, *)) {
        self.tableView.frame = CGRectMake(0, tableTop, bounds.size.width,
                                          bounds.size.height - tableTop - tableBottom);
        self.tableView.contentInset = UIEdgeInsetsZero;
    } else {
        self.tableView.frame = CGRectMake(0, tableTop, bounds.size.width, toolbarY - tableTop);
    }
    // Toolbar
    [self.toolbar setFrame:CGRectMake(0, toolbarY, bounds.size.width, 44)];
    // Toolbar下方一直延伸到屏幕底部，纯白填充
    if (!self.bottomFillView) {
        self.bottomFillView = [[UIView alloc] init];
        self.bottomFillView.backgroundColor = [UIColor whiteColor];
        [self.view insertSubview:self.bottomFillView belowSubview:self.toolbar];
    }
    self.bottomFillView.frame = CGRectMake(0, CGRectGetMaxY(self.toolbar.frame),
                                           bounds.size.width,
                                           bounds.size.height - CGRectGetMaxY(self.toolbar.frame));
}

#pragma mark - Setup

- (void)setupNavUI {
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.title = self.currentPath;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    // Right: ellipsis menu (lara style - New File/Folder, Paste, Sort, etc.)
    UIBarButtonItem *menuBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                              target:self
                                                                              action:@selector(addTapped)];
    self.navigationItem.rightBarButtonItem = menuBtn;

    // 左侧按钮：能往上就是「上一级」，到边界了才是「返回」。
    //
    // 以前它固定是 popViewController，所以从 App 管理器跳到 …/App.app 之后
    // 按返回会直接弹回 App 列表，没法看父目录；改成层级导航之后又要防止
    // 在 /var 下一步跳到 "/"。两道边界见 canGoUp。
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:([self canGoUp] ? SKLoc(@"fm.back.up")
                                                               : SKLoc(@"common.back"))
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(backTapped)];
}

- (void)setupTable {
    UITableViewStyle style = UITableViewStyleInsetGrouped;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 60;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 64, 0, 0);
    if (@available(iOS 11.0, *)) {
        self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.view addSubview:self.tableView];
}

- (void)setupSearch {
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
}

- (void)setupToolbar {
    self.toolbar = [[UIToolbar alloc] init];
    [self.view addSubview:self.toolbar];
}

- (void)updateToolbarItems {
    NSMutableArray *items = [NSMutableArray array];

    ClipboardItem *clip = gClipboard;
    UIBarButtonItem *pasteBtn;
    if (clip && ![self canModify]) {
        // 只读区：粘贴不可用（/ 下只允许查看与进入）
        pasteBtn = [[UIBarButtonItem alloc] initWithTitle:SKLoc(@"fm.readonlyShort")
                                                    style:UIBarButtonItemStylePlain
                                                   target:nil
                                                   action:nil];
        pasteBtn.enabled = NO;
    } else if (clip) {
        NSString *title = clip.isCut
            ? [NSString stringWithFormat:@"Move \"%@\" here", clip.name]
            : [NSString stringWithFormat:@"Copy \"%@\" here", clip.name];
        pasteBtn = [[UIBarButtonItem alloc] initWithTitle:title
                                                    style:UIBarButtonItemStylePlain
                                                   target:self
                                                   action:@selector(pasteHereTapped)];
    } else {
        pasteBtn = [[UIBarButtonItem alloc] initWithTitle:SKLoc(@"fm.clipboardEmpty")
                                                    style:UIBarButtonItemStylePlain
                                                   target:nil
                                                   action:nil];
        pasteBtn.enabled = NO;
    }

    UIBarButtonItem *flex1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                            target:nil
                                                                            action:nil];
    UIBarButtonItem *infoBtn = [[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:SKLoc(@"fm.itemsCount"),
                                                                        (unsigned long)self.fileList.count]
                                                                style:UIBarButtonItemStylePlain
                                                               target:nil
                                                               action:nil];
    infoBtn.enabled = NO;
    UIBarButtonItem *flex2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                            target:nil
                                                                            action:nil];
    NSString *shortPath = [self.currentPath isEqualToString:@"/var"] ? @"/var" : self.currentPath.lastPathComponent;
    UIBarButtonItem *rootBtn = [[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:@"%@", shortPath]
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(goToVarRoot)];

    [items addObject:pasteBtn];
    [items addObject:flex1];
    [items addObject:infoBtn];
    [items addObject:flex2];
    [items addObject:rootBtn];
    [self.toolbar setItems:items animated:YES];
}

- (void)goToVarRoot {
    // 回到本文件管理器的入口根（主菜单进来是 /var）。
    // 复用同一 VC 之后不能再 popToViewController —— 那会把自己弹掉。
    [self navigateTo:self.navRoot.length ? self.navRoot : @"/var"];
}

#pragma mark - .app 懒触发整树 chown（方法来自 FilzaJailedDS）

// Filza 能往 .app 里写，不是"绕过写检查"，而是**先把整棵 bundle 的属主改成
// mobile** —— 之后建文件 / 改名 / 粘贴全部走普通系统调用，包括变长内容。
//
// 触发时机照抄 Filza：每次列目录时，如果这个路径落在某个 .app 里，就把那个
// .app 作为一个整体在后台 chown 一次（每个 bundle 一次）。之所以要整棵而不是
// 单文件：目录的写权限才是关键，只改文件没用。
//
// apfs_own_tree 内部会跳过 _CodeSignature / SC_Info —— 改那两个会破坏代码
// 签名和 FairPlay，可能把 app 弄得打不开。

static NSMutableSet<NSString *> *gChownedApps = nil;
static dispatch_queue_t gChownQueue = NULL;

static NSString *SKAppRootForPath(NSString *path) {
    if (![path hasPrefix:@"/var/containers/Bundle/Application/"] &&
        ![path hasPrefix:@"/private/var/containers/Bundle/Application/"]) return nil;
    NSArray<NSString *> *comps = path.pathComponents;
    for (NSUInteger i = 0; i < comps.count; i++) {
        if ([comps[i] hasSuffix:@".app"]) {
            return [NSString pathWithComponents:[comps subarrayWithRange:NSMakeRange(0, i + 1)]];
        }
    }
    return nil;
}

static void SKEnsureAppChowned(NSString *path) {
    NSString *appRoot = SKAppRootForPath(path);
    if (!appRoot) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gChownedApps = [NSMutableSet new];
        gChownQueue = dispatch_queue_create("blade.autochown", DISPATCH_QUEUE_SERIAL);
    });

    @synchronized (gChownedApps) {
        if ([gChownedApps containsObject:appRoot]) return;
        [gChownedApps addObject:appRoot];   // 先标记，避免并发重复跑
    }

    if (!SKPathAllowsModify(appRoot)) return;   // 系统目录永不动

    dispatch_async(gChownQueue, ^{
        if (!ds_is_ready()) return;
        printf("[fm] 进入 .app，后台整树取得写权限: %s\n", appRoot.UTF8String);

        // 整棵树是一次内核操作：必须全程持锁，否则会和主线程的
        // sbx_escape / vfs / 扫描同时动内核原语 —— 那会直接 panic。
        // @try 接住 set_target_kaddr 抛出的 NSException（后台队列上没人接
        // 就是闪退），@finally 保证锁释放。
        long n = 0;
        [SKKernelLock() lock];
        @try {
            n = apfs_own_tree(appRoot.fileSystemRepresentation, 501, 501);
        } @catch (NSException *ex) {
            printf("[fm] 整树取得写权限抛异常 %s: %s\n", appRoot.UTF8String, ex.reason.UTF8String);
        } @finally {
            [SKKernelLock() unlock];
        }
        printf("[fm] %s 完成: %ld 项属主已改为 mobile\n", appRoot.UTF8String, n);
        // 一项都没改成说明这次没生效（例如原语还没就绪）。从已处理集合里撤掉，
        // 下次进这个 .app 还会再试 —— 之前是先标记再跑，失败就永不重试了。
        if (n <= 0) {
            @synchronized (gChownedApps) { [gChownedApps removeObject:appRoot]; }
            printf("[fm] %s 整树 chown 未生效，已撤销标记以便重试\n", appRoot.UTF8String);
        }
    });
}

// ── 只读区规则 ────────────────────────────────────────────────────────────
//
// 用户要求：默认从 "/" 进入，而 "/" 下只能"查看"和"进入目录"，其余一律不可用；
// 只有进到 /var 子树里这些功能才生效。
//
// 这不是权限问题（逃逸之后其实写得动 /System、/private 等），是刻意收窄：
// 从根往下漫游时最容易被误操作删/改系统目录，而真正要动手的地方（App 容器、
// .app、沙盒目录）全都在 /var 下面。
- (BOOL)canModify {
    return SKPathAllowsModify(self.currentPath);
}

- (void)notifyReadOnly {
    [self toast:SKLoc(@"fm.readonly")];
}



- (void)loadDirectory {
    // 每次刷新目录顺手确认一次写权限。
    //
    // 上一步如果是写/删文件，内核重建扩展表时会把我们的逃逸冲掉；
    // 这里探一次，丢了就立刻补回来——探针成功时零内核写。
    // 放在最前面：确保随后的浏览/操作都建立在"权限还在"的状态上。
    if (ds_is_ready()) [SKSandboxKeeper restoreIfLost:@"目录刷新"];

    // 进到某个 .app 就顺手把整棵 bundle 的属主改成 mobile（后台、每个只做一次）
    SKEnsureAppChowned(self.currentPath);

    [self.fileList removeAllObjects];

    // Browsing no longer rewrites ownership.
    //
    // This fired on every directory load and, inside an .app bundle or a data
    // container, recursively re-owned the whole tree. Simply looking at a folder
    // is not a reason to change who owns it.

    DIR *dir = opendir(self.currentPath.UTF8String);
    if (!dir) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                       message:[NSString stringWithFormat:SKLoc(@"fm.err.openFile"),
                                                                                self.currentPath, strerror(errno)]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    struct dirent *entry;
    NSMutableArray *dirs = [NSMutableArray array];
    NSMutableArray *files = [NSMutableArray array];

    while ((entry = readdir(dir)) != NULL) {
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;

        NSString *fullPath = [self.currentPath stringByAppendingPathComponent:name];

        // 符号链接必须单独认出来。
        //
        // 原来只 lstat 一次，S_ISLNK 落到 isDir=NO，于是软链被当成普通文件：
        // 点「/var」这种指向目录的软链不会进目录，而是去读文件；列表里也没有
        // 任何标记。更危险的是删除 —— recursive_delete_c 会 opendir() 跟随软链，
        // 删一个"指向目录的软链"会把目标目录整个递归删掉。所以这里同时解析
        // 目标类型，并把 isLink 单独记下来给删除逻辑用。
        BOOL isDir = NO;
        BOOL isLink = NO;
        BOOL isBrokenLink = NO;
        NSString *linkTarget = nil;
        struct stat lst;
        struct stat st;
        memset(&lst, 0, sizeof(lst));
        memset(&st, 0, sizeof(st));

        if (lstat(fullPath.UTF8String, &lst) == 0) {
            isLink = S_ISLNK(lst.st_mode);
            if (isLink) {
                char lbuf[PATH_MAX];
                memset(lbuf, 0, sizeof(lbuf));
                ssize_t n = readlink(fullPath.UTF8String, lbuf, sizeof(lbuf) - 1);
                if (n > 0) linkTarget = [NSString stringWithUTF8String:lbuf];
                if (stat(fullPath.UTF8String, &st) == 0) {
                    isDir = S_ISDIR(st.st_mode);       // 指向目录的软链 = 可以进去
                } else {
                    isBrokenLink = YES;                // 断链
                    st = lst;
                }
            } else {
                st = lst;
                isDir = S_ISDIR(st.st_mode);
            }
        } else if (stat(fullPath.UTF8String, &st) == 0) {
            isDir = S_ISDIR(st.st_mode);
        }

        // 类型位被抹掉的条目（fixC 的历史 bug 写过 07777）在这里救回来：
        // readdir 的 d_type 仍然知道它是不是目录，stat 的类型位却不认了。
        if (st.st_mode != 0 && (st.st_mode & S_IFMT) == 0) {
            if (entry->d_type == DT_DIR) st.st_mode |= S_IFDIR;
            else if (entry->d_type == DT_LNK) st.st_mode |= S_IFLNK;
            else if (entry->d_type == DT_REG) st.st_mode |= S_IFREG;
            isDir = S_ISDIR(st.st_mode);
        }

        NSDictionary *item = @{
            @"name": name,
            @"path": fullPath,
            @"isDir": @(isDir),
            @"size": @((unsigned long long)st.st_size),
            @"mode": @((unsigned int)st.st_mode),
            @"mtime": @((unsigned long)st.st_mtime),
            @"ctime": @((unsigned long)st.st_ctime),
            @"uid": @((unsigned int)st.st_uid),
            @"gid": @((unsigned int)st.st_gid),
            @"nlink": @((unsigned int)st.st_nlink),
            @"isLink": @(isLink),
            @"isBrokenLink": @(isBrokenLink),
            @"linkTarget": linkTarget ?: @""
        };

        if (isDir) [dirs addObject:item];
        else [files addObject:item];
    }
    closedir(dir);

    [dirs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];

    [self.fileList addObjectsFromArray:dirs];
    [self.fileList addObjectsFromArray:files];
    [self.tableView reloadData];
    [self updateToolbarItems];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *query = TrimStr(sc.searchBar.text);
    if (query.length == 0) {
        self.isSearching = NO;
        [self.filteredList removeAllObjects];
    } else {
        self.isSearching = YES;
        [self.filteredList removeAllObjects];
        for (NSDictionary *it in self.fileList) {
            NSString *name = it[@"name"];
            NSString *path = it[@"path"];
            if ([name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [path rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [self.filteredList addObject:it];
            }
        }
    }
    [self.tableView reloadData];
}

#pragma mark - TableView DataSource/Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.isSearching ? self.filteredList.count : self.fileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseId = @"FileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseId];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        if (@available(iOS 14.0, *)) {
            cell.backgroundConfiguration = [UIBackgroundConfiguration listSidebarCellConfiguration];
        }
    }

    NSDictionary *item = self.isSearching ? self.filteredList[indexPath.row] : self.fileList[indexPath.row];
    BOOL isDir = [item[@"isDir"] boolValue];
    NSString *name = item[@"name"];
    BOOL isHidden = [name hasPrefix:@"."];

    // SF Symbol icons (Filza-like)
    UIImage *icon = [self iconForItem:item];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular scale:UIImageSymbolScaleMedium];
        icon = [icon imageByApplyingSymbolConfiguration:cfg] ?: icon;
    }
    cell.imageView.image = icon;
    cell.imageView.tintColor = isDir ? [UIColor systemBlueColor] : [UIColor systemGrayColor];

    cell.textLabel.text = name;
    cell.textLabel.textColor = isHidden ? [UIColor systemGrayColor] : [UIColor labelColor];

    // Subtitle: type + size/date
    if ([item[@"isLink"] boolValue]) {
        NSString *tgt = item[@"linkTarget"];
        if ([item[@"isBrokenLink"] boolValue]) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"→ %@  •  %@",
                                            tgt.length ? tgt : @"?", SKLoc(@"fm.link.broken")];
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"→ %@%@", tgt,
                                            isDir ? [@"  " stringByAppendingString:SKLoc(@"fm.link.dir")] : @""];
            cell.detailTextLabel.textColor = [UIColor systemTealColor];
        }
    } else if (isDir) {
        unsigned count = 0;
        NSString *dir_path = item[@"path"];
        DIR *d = opendir(dir_path.UTF8String);
        if (d) { struct dirent *e; while ((e = readdir(d)) != NULL) { if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) count++; } closedir(d); }
        cell.detailTextLabel.text = [NSString stringWithFormat:SKLoc(@"fm.itemsCountU"),
                                        count, [self formatDate:[item[@"mtime"] unsignedLongValue]]];
    } else {
        uint64_t size = [item[@"size"] unsignedLongLongValue];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  •  %@",
                                        [self formatSize:size],
                                        [self formatDate:[item[@"mtime"] unsignedLongValue]]];
    }

    return cell;
}

- (UIImage *)iconForItem:(NSDictionary *)item API_AVAILABLE(ios(13.0)) {
    BOOL isDir = [item[@"isDir"] boolValue];
    BOOL isLink = [item[@"isLink"] boolValue];
    NSString *name = item[@"name"];

    if (isLink) {
        // 软链单独一个图标，指向哪在副标题里写清楚
        return [UIImage systemImageNamed:[item[@"isBrokenLink"] boolValue] ? @"link.badge.plus" : @"link"];
    }
    if (isDir) {
        // Blue folder icon like Filza
        return [UIImage systemImageNamed:@"folder.fill"];
    }

    NSString *ext = [[name lowercaseString] pathExtension];
    NSString *sysName = @"doc";

    // Images
    if ([@[@"png", @"jpg", @"jpeg", @"heic", @"heif", @"gif", @"webp", @"bmp", @"tif", @"tiff"] containsObject:ext]) {
        sysName = @"photo";
    }
    // Video/audio
    else if ([@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"] containsObject:ext]) {
        sysName = @"play.rectangle";
    }
    else if ([@[@"mp3", @"m4a", @"aac", @"flac", @"wav", @"caf", @"opus"] containsObject:ext]) {
        sysName = @"waveform";
    }
    // Text/code/plist
    else if ([@[@"txt", @"log", @"md", @"cfg", @"conf", @"json", @"xml", @"plist", @"strings", @"yml", @"yaml", @"sh", @"m", @"mm", @"h", @"c", @"cpp", @"swift"] containsObject:ext]) {
        sysName = @"doc.text";
    }
    // Archives
    else if ([@[@"zip", @"tar", @"gz", @"tgz", @"bz2", @"xz", @"7z", @"rar", @"deb", @"ipa"] containsObject:ext]) {
        sysName = @"zipper";
        if (![UIImage systemImageNamed:sysName]) sysName = @"doc.zipper";
    }
    // Binary / dylib
    else if ([@[@"dylib", @"so", @"framework", @"bundle"] containsObject:ext]) {
        sysName = @"cpu";
    }
    // PDF
    else if ([ext isEqualToString:@"pdf"]) {
        sysName = @"doc.richtext";
    }

    UIImage *img = [UIImage systemImageNamed:sysName];
    if (!img) img = [UIImage systemImageNamed:@"doc"];
    return img;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.isSearching ? self.filteredList[indexPath.row] : self.fileList[indexPath.row];
    if ([item[@"isDir"] boolValue]) {
        HapticSelect();
        [self navigateTo:item[@"path"]];
    } else {
        HapticLight();
        NSString *ext = ((NSString *)item[@"name"]).pathExtension.lowercaseString;
        if ([ext isEqualToString:@"zip"]) {
            [self extractZip:item];
        } else {
            [self openFileViewerForItem:item];
        }
    }
}

#pragma mark - Long press (Filza-style action sheet)

- (void)handleLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    HapticMedium();
    CGPoint p = [sender locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:p];
    if (!indexPath) return;
    NSDictionary *item = self.isSearching ? self.filteredList[indexPath.row] : self.fileList[indexPath.row];
    [self showLongPressMenuForItem:item atIndexPath:indexPath];
}

- (void)showLongPressMenuForItem:(NSDictionary *)item atIndexPath:(NSIndexPath *)indexPath {
    BOOL isDir = [item[@"isDir"] boolValue];
    BOOL canMod = [self canModify];   // / 下只留"查看"和"复制路径"

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil
                                                                   message:item[@"path"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Copy (lara-style - to app clipboard, not string)
    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.copy")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        ClipboardItem *ci = [[ClipboardItem alloc] init];
        ci.path = item[@"path"];
        ci.isDir = isDir;
        ci.name = item[@"name"];
        ci.isCut = NO;
        gClipboard = ci;
        HapticSelect();
        [self updateToolbarItems];
        [self toast:SKLoc(@"fm.copied")];
    }]];

    // Cut (Move)
    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.cut")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        ClipboardItem *ci = [[ClipboardItem alloc] init];
        ci.path = item[@"path"];
        ci.isDir = isDir;
        ci.name = item[@"name"];
        ci.isCut = YES;
        gClipboard = ci;
        HapticSelect();
        [self updateToolbarItems];
        [self toast:SKLoc(@"fm.row.cutHint")];
    }]];

    // Rename
    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.rename")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showRenameDialogForItem:item];
    }]];

    // Compress ZIP (files AND directories)
    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.zip")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        HapticLight();
        [self compressToZip:item];
    }]];

    // Extract ZIP (if .zip extension)
    NSString *ext = ((NSString *)item[@"name"]).pathExtension.lowercaseString;
    if (!isDir && [ext isEqualToString:@"zip"]) {
        if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.unzip")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            HapticLight();
            [self extractZip:item];
        }]];
    }

    // Chmod (permissions)
    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.chmod")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showChmodSheet:item];
    }]];

    // Chown (owner/group) — the ordinary syscall. As uid 501 this always fails,
    // because vnode_authorize(KAUTH_VNODE_CHANGE_OWNER) requires uid 0. Kept
    // because it is the right tool once root is actually available.
    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.chown")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showChownSheet:item];
    }]];

    // Copy path (系统剪贴板，可以直接粘到别处)
    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.copypath")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self copyPathToPasteboard:item[@"path"]];
    }]];

    // Properties (editable)
    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.props")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self showPropertiesForItem:item];
    }]];

    // Delete
    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.delete")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [self showDeleteConfirmForItem:item];
    }]];

    // Cancel
    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *pop = menu.popoverPresentationController;
    if (pop) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        pop.sourceView = cell;
        pop.sourceRect = cell.bounds;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

#pragma mark - Clipboard Paste Here

- (void)pasteHereTapped {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    ClipboardItem *ci = gClipboard;
    if (!ci) return;

    NSString *dest = [self.currentPath stringByAppendingPathComponent:ci.name];
    if ([ci.path isEqualToString:dest]) {
        [self toast:SKLoc(@"fm.samePath")];
        return;
    }
    if (ci.isDir && ([dest hasPrefix:[ci.path stringByAppendingString:@"/"]] || [dest isEqualToString:ci.path])) {
        [self toast:SKLoc(@"fm.pasteIntoSelf")];
        return;
    }

    // Avoid overwriting existing item (lara style - append "copy")
    NSString *finalDest = uniquePath(dest);

    // 粘贴/移动同样是落盘操作：先确保写权限在，否则必然 EPERM。
    if (ds_is_ready()) [SKSandboxKeeper ensureWriteAccess];

    BOOL ok;
    if (ci.isCut) {
        ok = moveItem(ci.path, finalDest);
        if (ok) gClipboard = nil; // clear clipboard after successful move
    } else {
        ok = copyItem(ci.path, finalDest);
        // copy keeps clipboard
    }

    // .app 里目录不可写 → 先用内核取父目录属主再试一次
    if (!ok && SKKernelOwnParent(finalDest)) {
        ok = ci.isCut ? moveItem(ci.path, finalDest) : copyItem(ci.path, finalDest);
        if (ok && ci.isCut) gClipboard = nil;
    }

    if (ok) {
        if (ds_is_ready()) [SKSandboxKeeper restoreIfLost:ci.isCut ? @"移动文件" : @"复制文件"];
        [self toast:ci.isCut ? @"Moved" : @"Copied"];
        [self loadDirectory];
    } else {
        [self showAlertTitle:SKLoc(@"fm.op.failed") msg:[NSString stringWithFormat:@"%s", strerror(errno)]];
    }
}

#pragma mark - Rename / Delete dialogs

- (void)showRenameDialogForItem:(NSDictionary *)item {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.row.rename") message:nil
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = item[@"name"];
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.rename") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *newName = TrimStr(alert.textFields.firstObject.text);
        if (newName.length == 0 || [newName containsString:@"/"]) {
            [self showAlertTitle:SKLoc(@"fm.rename.invalid") msg:nil];
            return;
        }
        NSString *newPath = [[item[@"path"] stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];
        if ([newPath isEqualToString:item[@"path"]]) return;
        clearImmutableFlag(item[@"path"]);
        int rr = rename(utf8Str(item[@"path"]), newPath.UTF8String);
        if (rr != 0 && SKKernelOwnParent(newPath)) {
            // .app 里改名要在目录上有写权限，内核改属主后重试
            rr = rename(utf8Str(item[@"path"]), newPath.UTF8String);
        }
        if (rr == 0) {
            [self loadDirectory];
        } else {
            [self showAlertTitle:SKLoc(@"fm.rename.failed") msg:[NSString stringWithFormat:@"%s", strerror(errno)]];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showDeleteConfirmForItem:(NSDictionary *)item {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    NSString *msg = [NSString stringWithFormat:SKLoc(@"fm.del.title"), item[@"name"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.del.confirm")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        // 软链一律按 unlink 处理：recursive_delete_c 会跟随软链把目标目录删空。
        BOOL isLink = [item[@"isLink"] boolValue];
        BOOL isDir = [item[@"isDir"] boolValue] && !isLink;
        // 先确认写权限还在。掉了就先补回来，否则这次 unlink 必然 EPERM，
        // 报出来的错又和"文件本身没权限"混在一起，没法区分。
        if (ds_is_ready()) [SKSandboxKeeper ensureWriteAccess];
        if (isLink) lchflags(utf8Str(item[@"path"]), 0);   // 只清软链自己的标志位
        else clearImmutableFlag(item[@"path"]);
        int r = SKDeleteWithRecovery(item[@"path"], isDir);
        if (r == 0) {
            // 删除落盘同样会冲掉逃逸，立刻补回来，别让下一个操作踩空。
            if (ds_is_ready()) [SKSandboxKeeper restoreIfLost:@"删除文件"];
            [self loadDirectory];
        } else {
            int err = errno;
            [self showAlertTitle:SKLoc(@"fm.del.failed") msg:SKFailureDetail(item[@"path"], err)];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - ZIP compression (files AND directories)

- (void)compressToZip:(NSDictionary *)item {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    NSString *srcPath = item[@"path"];
    NSString *zipName = [srcPath.lastPathComponent stringByAppendingString:@".zip"];
    NSString *zipPath = [self.currentPath stringByAppendingPathComponent:zipName];
    NSString *finalZip = uniquePath(zipPath);

    [self toast:@"Compressing..." duration:0.5];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *err = zipPathTo(srcPath, finalZip);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!err) {
                [self toast:SKLoc(@"fm.zip.ok")];
                [self loadDirectory];
            } else {
                [self showAlertTitle:SKLoc(@"fm.zip.failed") msg:err];
            }
        });
    });
}

#pragma mark - Chmod sheet (editable permissions)

- (void)showChmodSheet:(NSDictionary *)item {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    struct stat st;
    if (stat(utf8Str(item[@"path"]), &st) != 0) {
        [self showAlertTitle:SKLoc(@"fm.stat.failed") msg:[NSString stringWithFormat:@"%s", strerror(errno)]];
        return;
    }

    // 可视化编辑器（Filza 风格）：3x3 开关 + 特殊位，八进制实时显示。
    // 原来只给一个输入框敲 0755，看不出每一位是什么，敲错了也说不清哪里错。
    SKPermsEditor *ed = [[SKPermsEditor alloc] initWithPath:item[@"path"]
                                                      mode:(unsigned int)(st.st_mode & 07777)
                                                     isDir:[item[@"isDir"] boolValue]];
    __weak typeof(self) weakSelf = self;
    ed.onApplied = ^(unsigned int newMode) {
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;
        [self_ toast:SKLoc(@"fm.chmod.ok")];
        [self_ loadDirectory];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:ed];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Chown sheet (editable uid/gid)

- (void)showChownSheet:(NSDictionary *)item {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    struct stat st;
    if (stat(utf8Str(item[@"path"]), &st) != 0) {
        [self showAlertTitle:SKLoc(@"fm.stat.failed") msg:[NSString stringWithFormat:@"%s", strerror(errno)]];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.row.chown")
                                                                   message:item[@"path"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [sheet addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = [NSString stringWithFormat:SKLoc(@"fm.chown.uid"), st.st_uid];
        tf.text = [NSString stringWithFormat:@"%d", st.st_uid];
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [sheet addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = [NSString stringWithFormat:SKLoc(@"fm.chown.gid"), st.st_gid];
        tf.text = [NSString stringWithFormat:@"%d", st.st_gid];
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [sheet addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        int uid = st.st_uid, gid = st.st_gid;
        NSString *u = TrimStr(sheet.textFields[0].text);
        NSString *g = TrimStr(sheet.textFields[1].text);
        if (u.length) uid = u.intValue;
        if (g.length) gid = g.intValue;
        clearImmutableFlag(item[@"path"]);
        // 普通 chown 走 vnode_authorize；app bundle 这类目标即使属主是自己也会
        // 被 restricted 标志 / 沙盒拒掉。失败就回落到内核路径 apfs_own。
        BOOL chownOk = (chown(utf8Str(item[@"path"]), (uid_t)uid, (gid_t)gid) == 0);
        if (!chownOk && ds_is_ready()) {
            printf("[fm] chown %s -> %d:%d 被拒 (%s)，改用内核路径\n",
                   utf8Str(item[@"path"]), uid, gid, strerror(errno));
            [SKKernelLock() lock];
            @try {
                chownOk = (apfs_own(utf8Str(item[@"path"]), (uid_t)uid, (gid_t)gid) == 0);
            } @catch (NSException *ex) {
                printf("[fm] apfs_own 抛异常: %s\n", ex.reason.UTF8String);
                chownOk = NO;
            } @finally {
                [SKKernelLock() unlock];
            }
        }
        if (chownOk) {
            [self toast:SKLoc(@"fm.chown.ok")];
            [self loadDirectory];
        } else {
            [self showAlertTitle:SKLoc(@"fm.chown.failed") msg:[NSString stringWithFormat:@"%s", strerror(errno)]];
        }
    }]];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Properties (with editable fields)


- (void)showPropertiesForItem:(NSDictionary *)item {
    struct stat st;
    memset(&st, 0, sizeof(st));
    stat(utf8Str(item[@"path"]), &st);

    NSString *kind = [item[@"isDir"] boolValue] ? @"Directory" : @"File";
    uint64_t size = [item[@"size"] unsignedLongLongValue];
    NSString *sizeStr = [item[@"isDir"] boolValue] ? @"—" : [self formatSize:size];
    NSString *modeStr = [NSString stringWithFormat:@"%04o", st.st_mode & 07777];

    NSMutableString *info = [NSMutableString string];
    [info appendFormat:@"%@ %@\n", SKLoc(@"fm.props.name"), item[@"name"]];
    [info appendFormat:@"%@ %@\n", SKLoc(@"fm.props.path"), item[@"path"]];
    [info appendFormat:@"%@ %@\n", SKLoc(@"fm.props.kind"), kind];
    if ([item[@"isLink"] boolValue]) {
        [info appendFormat:@"%@ → %@%@\n", SKLoc(@"fm.props.link"), item[@"linkTarget"],
            [item[@"isBrokenLink"] boolValue] ? [@"  " stringByAppendingString:SKLoc(@"fm.link.broken")] : @""];
    }
    [info appendFormat:@"%@ %@\n", SKLoc(@"fm.props.size"), sizeStr];
    [info appendFormat:@"%@ %@\n", SKLoc(@"fm.props.perms"), modeStr];
    // 注意：st_uid/st_gid 是整数，绝不能用 %@ —— %@ 会把整数当对象指针去发
    // description，直接 EXC_BAD_ACCESS 闪退。这就是"点属性就崩"的原因。
    [info appendFormat:@"%@ %u\n", SKLoc(@"fm.props.uid"), (unsigned int)st.st_uid];
    [info appendFormat:@"%@ %u\n", SKLoc(@"fm.props.gid"), (unsigned int)st.st_gid];
    [info appendFormat:@"%@ %lu\n", SKLoc(@"fm.props.links"), (unsigned long)st.st_nlink];
    [info appendFormat:@"%@ %@\n", SKLoc(@"fm.props.modified"), [self formatDate:[item[@"mtime"] unsignedLongValue]]];
    [info appendFormat:@"%@ %@", SKLoc(@"fm.props.changed"), [self formatDate:[item[@"ctime"] unsignedLongValue]]];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Properties"
                                                                   message:info
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.row.copypath") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self copyPathToPasteboard:item[@"path"]];
    }]];
    if ([self canModify]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Chmod" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self showChmodSheet:item];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Chown" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self showChownSheet:item];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Add menu (right bar button, lara-style)

- (void)addTapped {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil
                                                                   message:self.currentPath
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    BOOL canMod = [self canModify];

    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.menu.createFile")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self promptForName:@"file"];
    }]];

    if (canMod) [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.menu.newFolder")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self promptForName:@"folder"];
    }]];

    if (canMod && gClipboard) {
        [menu addAction:[UIAlertAction actionWithTitle:
                            [NSString stringWithFormat:SKLoc(@"fm.menu.pasteNamed"), gClipboard.name]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [self pasteHereTapped];
        }]];
    }

    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.menu.jumpVar")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self goToVarRoot];
    }]];

    // 跳到自己的沙盒。这是唯一一个「文件」App 能往里放东西、同时本 App 又
    // 看得到的位置（UIFileSharingEnabled 暴露的就是 Documents），所以想做
    // 「把外部文件导入文件管理器」就得先能走到这里，再把文件粘进来。
    NSString *sandboxDocs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.menu.sandboxDocs")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self pushPath:sandboxDocs];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.menu.sandboxRoot")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self pushPath:NSHomeDirectory()];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.menu.tags")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        SKFMTagsViewController *vc = [[SKFMTagsViewController alloc] initWithCurrentPath:self.currentPath];
        [self.navigationController pushViewController:vc animated:YES];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.menu.refresh")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self loadDirectory];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *pop = menu.popoverPresentationController;
    if (pop) {
        pop.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)pushPath:(NSString *)path {
    if (!path.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        [self showAlertTitle:SKLoc(@"fm.tags.missing") msg:path];
        return;
    }
    if (!isDir) path = path.stringByDeletingLastPathComponent;
    [self navigateTo:path];
}

- (void)promptForName:(NSString *)type {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    NSString *title = [type isEqualToString:@"folder"] ? SKLoc(@"fm.menu.newFolder") : SKLoc(@"fm.menu.createFile");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Enter name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = TrimStr(alert.textFields.firstObject.text);
        if (name.length == 0 || [name containsString:@"/"]) {
            [self showAlertTitle:SKLoc(@"fm.rename.invalid") msg:nil];
            return;
        }
        NSString *newPath = [self.currentPath stringByAppendingPathComponent:name];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:newPath]) {
            [self showAlertTitle:@"Already exists" msg:nil];
            return;
        }
        NSError *err = nil;
        BOOL ok = NO;
        BOOL isFolder = [type isEqualToString:@"folder"];

        printf("[fm] 创建 %s: %s\n", isFolder ? "目录" : "文件", newPath.UTF8String);

        // 第一次尝试：普通创建。
        if (isFolder) {
            ok = [fm createDirectoryAtPath:newPath withIntermediateDirectories:NO attributes:nil error:&err];
        } else {
            ok = [fm createFileAtPath:newPath contents:nil attributes:nil];
        }

        // .app 这类目录属主是 root，普通创建必然 EACCES。用内核改父目录属主后再试。
        if (!ok) printf("[fm] 普通创建失败: %s\n", strerror(errno));
        if (!ok && SKKernelOwnParent(newPath)) {
            printf("[fm] 取父目录属主后重试创建\n");
            err = nil;
            if (isFolder) {
                ok = [fm createDirectoryAtPath:newPath withIntermediateDirectories:NO attributes:nil error:&err];
            } else {
                ok = [fm createFileAtPath:newPath contents:nil attributes:nil];
            }
        }

        if (ok) {
            printf("[fm] 创建成功，刷新目录\n");
            [self loadDirectory];
        } else {
            printf("[fm] 创建失败: %s\n", strerror(errno));
            [self showAlertTitle:SKLoc(@"fm.create.failed")
                             msg:err.localizedDescription ?: [NSString stringWithFormat:@"%s", strerror(errno)]];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Helpers

// 换目录。
//
// 必须复用同一个 VC，不能 push 父目录：上一版是 push，导航栈就往上长，
// 到了边界再「返回」时 pop 回来的是**子目录**（刚走下来的那个），按几次就在
// 两个目录之间来回跳，永远退不出去 —— 用户报的"无法退出文件管理器"。
- (void)navigateTo:(NSString *)path {
    if (path.length == 0) return;
    self.currentPath = path;
    self.title = path;
    [self setupNavUI];      // 刷新标题和左侧按钮（能上/到边界）
    [self loadDirectory];
}

// 退出文件管理器：入口是导航栈根就关掉整个导航，否则 pop 回上一层页面。
- (void)exitFileManager {
    UINavigationController *nav = self.navigationController;
    if (!nav) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (nav.viewControllers.firstObject == self) {
        [nav dismissViewControllerAnimated:YES completion:nil];
    } else {
        [nav popViewControllerAnimated:YES];
    }
}

// 还能不能往上走。
//
// 两道边界：不能越过 "/"；默认也不能越过入口路径（navRoot）——
// 从主菜单进来的入口是 /var，越过去一步就是 "/"，用户报的就是这个。
// App 管理器那种跳转把 allowEscapeAboveRoot 打开，才允许一直往上。
- (BOOL)canGoUp {
    if ([self.currentPath isEqualToString:@"/"]) return NO;
    if (!self.allowEscapeAboveRoot && [self.currentPath isEqualToString:self.navRoot]) return NO;
    return YES;
}

- (void)backTapped {
    if (![self canGoUp]) {
        // 到边界了：var 下这里是"回主页面"，App 跳转那边是"回 App 列表"
        [self exitFileManager];
        return;
    }
    NSString *parent = [self.currentPath stringByDeletingLastPathComponent];
    if (parent.length == 0) parent = @"/";
    [self navigateTo:parent];
}

// 复制路径到系统剪贴板
- (void)copyPathToPasteboard:(NSString *)path {
    if (path.length == 0) return;
    [UIPasteboard generalPasteboard].string = path;
    HapticSelect();
    [self toast:SKLoc(@"fm.copied.path")];
}

- (void)toast:(NSString *)msg {
    [self toast:msg duration:1.2];
}

- (void)toast:(NSString *)msg duration:(NSTimeInterval)dur {
    UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:toast animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [toast dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)showAlertTitle:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSString *)formatSize:(uint64_t)size {
    if (size < 1024) return [NSString stringWithFormat:@"%llu B", size];
    if (size < 1024*1024) return [NSString stringWithFormat:@"%.1f KB", size/1024.0];
    if (size < 1024ULL*1024*1024) return [NSString stringWithFormat:@"%.1f MB", size/(1024.0*1024.0)];
    return [NSString stringWithFormat:@"%.2f GB", size/(1024.0*1024.0*1024.0)];
}

- (NSString *)formatDate:(unsigned long)ts {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterShortStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
    });
    return [fmt stringFromDate:d];
}

#pragma mark - Extract ZIP

- (void)extractZip:(NSDictionary *)item {
    if (![self canModify]) { [self notifyReadOnly]; return; }
    NSString *zipPath = item[@"path"];
    NSString *folderName = [zipPath.lastPathComponent stringByDeletingPathExtension];
    NSString *dstDir = [[zipPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:folderName];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    unsigned tries = 0;
    NSString *finalDst = dstDir;
    while ([fm fileExistsAtPath:finalDst isDirectory:&isDir]) {
        tries++;
        finalDst = [dstDir stringByAppendingFormat:@"-%u", tries];
    }
    NSString *err = unzipFileTo(zipPath, finalDst);
    if (err) {
        [self showAlertTitle:SKLoc(@"fm.unzip.failed") msg:err];
    } else {
        [self toast:@"Extracted"];
        [self loadDirectory];
    }
}

#pragma mark - File Viewer Routing

static NSSet<NSString *> *TextExts(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"txt",@"text",@"log",@"json",@"xml",@"plist",@"md",@"markdown",
                                  @"cfg",@"conf",@"ini",@"cnf",@"csv",@"tsv",@"tab",
                                  @"sh",@"bash",@"zsh",@"py",@"rb",@"pl",@"php",@"js",@"ts",
                                  @"css",@"scss",@"html",@"htm",@"xhtml",
                                  @"m",@"h",@"mm",@"c",@"cc",@"cpp",@"cxx",@"hpp",@"swift",
                                  @"java",@"kt",@"scala",@"go",@"rs",@"sql",@"yaml",@"yml",
                                  @"makefile",@"cmake",@"cmakein",@"am",@"ac",@"m4",
                                  @"dockerfile",@"env",@"gitignore",@"gitconfig",
                                  @"plist",@"strings",@"entitlements",@"lproj",@"nib",@"storyboard"]];
    });
    return s;
}

static NSSet<NSString *> *ImageExts(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"png",@"jpg",@"jpeg",@"gif",@"bmp",@"tiff",@"tif",@"heic",@"heif",
                                  @"webp",@"ico",@"cur",@"pdf"]];
    });
    return s;
}

static NSSet<NSString *> *MediaExts(void) {
    static NSSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"mp4",@"mov",@"m4v",@"3gp",@"avi",
                                  @"mp3",@"m4a",@"aac",@"caf",@"wav",@"aiff",@"aif",
                                  @"flac",@"alac",@"wma",@"ogg",@"opus"]];
    });
    return s;
}

- (void)openFileViewerForItem:(NSDictionary *)item {
    NSString *path = item[@"path"];
    NSString *ext = ((NSString *)item[@"name"]).pathExtension.lowercaseString;
    if ([ImageExts() containsObject:ext]) {
        FMImageViewController *vc = [[FMImageViewController alloc] initWithPath:path];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([MediaExts() containsObject:ext]) {
        NSURL *url = [NSURL fileURLWithPath:path];
        AVPlayer *player = [AVPlayer playerWithURL:url];
        AVPlayerViewController *pvc = [[AVPlayerViewController alloc] init];
        pvc.player = player;
        [player play];
        [self presentViewController:pvc animated:YES completion:nil];
    } else if ([SKFMPlistEditorViewController looksLikePlist:path]) {
        // plist 要用结构化编辑器：二进制 plist 在文本编辑器里是乱码，存下去
        // 会把文件写坏
        SKFMPlistEditorViewController *vc = [[SKFMPlistEditorViewController alloc] initWithPath:path];
        if (vc) {
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            [self showAlertTitle:SKLoc(@"fm.plist.unparsable") msg:path];
        }
    } else {
        // Text viewer: text extensions, or unknown < 3MB
        unsigned long long size = [item[@"size"] unsignedLongLongValue];
        BOOL looksText = [TextExts() containsObject:ext] || size <= (3 * 1024 * 1024);
        if (looksText) {
            FMTextEditorViewController *vc = [[FMTextEditorViewController alloc] initWithPath:path];
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            [self showPropertiesForItem:item];
        }
    }
}

@end

