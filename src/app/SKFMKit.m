//
//  SKFMKit.m
//  AppDump
//

#import "SKFMKit.h"
#import "SKLog.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#import "apfs.h"
#import "darksword.h"
#import "SKKernelLock.h"

#pragma mark - 剪贴板

@implementation SKFMClipItem
@end

@implementation SKFMClipboard
+ (instancetype)shared {
    static SKFMClipboard *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SKFMClipboard new]; });
    return s;
}
@end

#pragma mark - 可写判断

BOOL SKFMWritable(NSString *path) {
    if (!path.length) return NO;
    struct stat st;
    const char *p = path.fileSystemRepresentation;
    if (stat(p, &st) != 0) return NO;
    if (!S_ISDIR(st.st_mode)) return NO;
    // access() 按真实 uid 判权限：UID=0 的目录（/、/var、/System…）在 501 身份下
    // 一律 EACCES，正是「不可写就不给写」要的结果。
    return access(p, W_OK) == 0;
}

BOOL SKFMItemWritable(NSString *path) {
    return SKFMWritable(path.stringByDeletingLastPathComponent);
}

#pragma mark - 路径

NSString *SKFMUniquePath(NSString *base) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:base]) return base;

    NSString *dir = base.stringByDeletingLastPathComponent;
    NSString *file = base.lastPathComponent;
    NSString *ext = file.pathExtension;
    NSString *stem = ext.length ? file.stringByDeletingPathExtension : file;

    for (NSInteger i = 1; i < 10000; i++) {
        NSString *suffix = i == 1 ? @" copy" : [NSString stringWithFormat:@" copy %ld", (long)i];
        NSString *name = ext.length ? [NSString stringWithFormat:@"%@%@.%@", stem, suffix, ext]
                                    : [NSString stringWithFormat:@"%@%@", stem, suffix];
        NSString *cand = [dir stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:cand]) return cand;
    }
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ copy %d", stem, arc4random()]];
}

void SKFMClearImmutable(NSString *path) {
    // 不可变位会让 remove/move/write 直接失败，且只有 iOS 16 上暴露给用户进程。
    [[NSFileManager defaultManager] setAttributes:@{ NSFileImmutable: @(NO) }
                                     ofItemAtPath:path
                                            error:nil];
}

#pragma mark - 基本操作

BOOL SKFMWriteData(NSString *path, NSData *data, NSError **err) {
    SKFMClearImmutable(path);
    return [data writeToFile:path options:NSDataWritingAtomic error:err];
}

BOOL SKFMCreateDirectory(NSString *path, NSError **err) {
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
                                     withIntermediateDirectories:NO
                                                      attributes:nil
                                                           error:err];
}

BOOL SKFMRemoveItem(NSString *path, NSError **err) {
    SKFMClearImmutable(path);
    return [[NSFileManager defaultManager] removeItemAtPath:path error:err];
}

BOOL SKFMCopyItem(NSString *from, NSString *to, NSError **err) {
    return [[NSFileManager defaultManager] copyItemAtPath:from toPath:to error:err];
}

BOOL SKFMMoveItem(NSString *from, NSString *to, NSError **err) {
    SKFMClearImmutable(from);
    return [[NSFileManager defaultManager] moveItemAtPath:from toPath:to error:err];
}

#pragma mark - chmod / chown

BOOL SKFMChmod(NSString *path, unsigned int mode, BOOL isDir) {
    SKFMClearImmutable(path);

    const char *p = path.fileSystemRepresentation;
    errno = 0;
    if (chmod(p, (mode_t)mode) == 0) return YES;

    int firstErr = errno;
    if (!ds_is_ready()) {
        SKLog(@"[fm] chmod %@ -> %04o failed: %s", path, mode, strerror(firstErr));
        return NO;
    }

    // chmod() 走 vnode_authorize，iOS 会因为 vnode 的 restricted 位或沙盒的
    // file-write-mode 检查把它拒掉；内核路径直接写 APFS inode 的 mode。
    BOOL ok = NO;
    [SKKernelLock() lock];
    @try {
        struct stat cur;
        mode_t type = 0;
        if (stat(p, &cur) == 0) type = (cur.st_mode & S_IFMT);
        if (type == 0) type = isDir ? S_IFDIR : S_IFREG;
        ok = (apfs_mod(p, (mode_t)(type | (mode & 07777))) == 0);
    } @catch (NSException *ex) {
        SKLog(@"[fm] apfs_mod threw: %@", ex.reason);
        ok = NO;
    } @finally {
        [SKKernelLock() unlock];
    }

    if (ok) {
        struct stat st;
        ok = (stat(p, &st) == 0) && ((st.st_mode & 07777) == (mode & 07777));
    }
    SKLog(@"[fm] chmod %@ -> %04o %@", path, mode, ok ? @"ok" : @"failed");
    return ok;
}

BOOL SKFMChown(NSString *path, unsigned int uid, unsigned int gid) {
    SKFMClearImmutable(path);

    const char *p = path.fileSystemRepresentation;
    errno = 0;
    if (chown(p, (uid_t)uid, (gid_t)gid) == 0) return YES;

    int firstErr = errno;
    if (!ds_is_ready()) {
        SKLog(@"[fm] chown %@ -> %u:%u failed: %s", path, uid, gid, strerror(firstErr));
        return NO;
    }

    BOOL ok = NO;
    [SKKernelLock() lock];
    @try {
        ok = (apfs_own(p, (uid_t)uid, (gid_t)gid) == 0);
    } @catch (NSException *ex) {
        SKLog(@"[fm] apfs_own threw: %@", ex.reason);
        ok = NO;
    } @finally {
        [SKKernelLock() unlock];
    }

    if (ok) {
        struct stat st;
        ok = (stat(p, &st) == 0) && (st.st_uid == (uid_t)uid) && (st.st_gid == (gid_t)gid);
    }
    SKLog(@"[fm] chown %@ -> %u:%u %@", path, uid, gid, ok ? @"ok" : @"failed");
    return ok;
}

UIAlertController *SKFMAlert(NSString *title, NSString *message) {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    return al;
}

#pragma mark - Get Info

@interface SKFMInfoViewController () <UITableViewDataSource>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *sections;   // [[title, value]...]
@property (nonatomic, strong) NSArray<NSString *> *headers;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) unsigned long long size;
@end

@implementation SKFMInfoViewController

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) _path = [path copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"文件信息";
    self.name = self.path.lastPathComponent.length ? self.path.lastPathComponent : @"/";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(close)];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    [self.view addSubview:self.table];

    [self buildDetails];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)buildDetails {
    struct stat st, lst;
    BOOL linked = lstat(self.path.fileSystemRepresentation, &lst) == 0 && S_ISLNK(lst.st_mode);
    if (stat(self.path.fileSystemRepresentation, &st) != 0) {
        self.sections = @[ @[ @"路径", self.path ], @[ @"状态", @"无法读取" ] ];
        self.headers = @[ @"文件", @"信息" ];
        return;
    }
    self.isDir = S_ISDIR(st.st_mode);
    if (!self.isDir) self.size = (unsigned long long)st.st_size;

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateStyle = NSDateFormatterMediumStyle;
    df.timeStyle = NSDateFormatterShortStyle;

    NSString *created = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:st.st_birthtimespec.tv_sec]];
    NSString *modified = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:st.st_mtimespec.tv_sec]];

    NSString *uttype = @"—";
    if (!self.isDir) {
        NSString *ext = self.path.pathExtension;
        if (ext.length) {
            UTType *t = [UTType typeWithFilenameExtension:ext];
            if (t.identifier.length) uttype = t.identifier;
        } else {
            uttype = @"public.data";
        }
    }

    NSString *owner = [NSString stringWithFormat:@"%u", st.st_uid];
    NSString *group = [NSString stringWithFormat:@"%u", st.st_gid];

    self.sections = @[
        @[ @"创建时间", created ],
        @[ @"修改时间", modified ],
        @[ @"类型", uttype ],
        @[ @"符号链接", linked ? @"true" : @"false" ],
        @[ @"权限", [NSString stringWithFormat:@"%04o", (unsigned)(st.st_mode & 07777)] ],
        @[ @"所有者 UID", owner ],
        @[ @"所有者 GID", group ],
        @[ @"可读", access(self.path.fileSystemRepresentation, R_OK) == 0 ? @"true" : @"false" ],
        @[ @"可写", access(self.path.fileSystemRepresentation, W_OK) == 0 ? @"true" : @"false" ],
        @[ @"可执行", access(self.path.fileSystemRepresentation, X_OK) == 0 ? @"true" : @"false" ],
        @[ @"路径", self.path ],
    ];
    self.headers = @[ @"文件信息", @"权限" ];
    [self.table reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return nil;
    // 前四条是时间/类型，后面是权限
    return self.headers.count > 1 ? (s == 1 ? self.headers[0] : self.headers[1]) : nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return MIN((NSInteger)4, (NSInteger)self.sections.count);
    return MAX((NSInteger)0, (NSInteger)self.sections.count - 4);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"i";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *cc = [c defaultContentConfiguration];

    if (ip.section == 0) {
        cc.image = [UIImage systemImageNamed:self.isDir ? @"folder.fill" : @"doc"];
        cc.imageProperties.tintColor = self.isDir ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
        NSString *sub = self.isDir ? @"文件夹"
                                   : [NSByteCountFormatter stringFromByteCount:(long long)self.size
                                                                  countStyle:NSByteCountFormatterCountStyleFile];
        cc.text = self.name;
        cc.secondaryText = sub;
        c.contentConfiguration = cc;
        return c;
    }

    NSInteger idx = ip.section == 1 ? ip.row : 4 + ip.row;
    if (idx < (NSInteger)self.sections.count) {
        NSArray<NSString *> *kv = self.sections[idx];
        cc.text = kv[0];
        cc.secondaryText = kv[1];
        cc.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cc.secondaryTextProperties.numberOfLines = 3;
        // true/false 用打勾/叉更直观（不是 emoji，是 SF Symbol）
        if ([kv[1] isEqualToString:@"true"] || [kv[1] isEqualToString:@"false"]) {
            cc.secondaryText = nil;
            c.accessoryView = [[UIImageView alloc] initWithImage:
                [UIImage systemImageNamed:[kv[1] isEqualToString:@"true"] ? @"checkmark" : @"xmark"]];
            c.accessoryView.tintColor = [kv[1] isEqualToString:@"true"] ? UIColor.systemGreenColor
                                                                      : UIColor.systemRedColor;
            [c.accessoryView sizeToFit];
        } else {
            c.accessoryView = nil;
        }
    }
    c.contentConfiguration = cc;
    return c;
}

@end

#pragma mark - Create File

@interface SKFMNewFileViewController () <UITextViewDelegate>
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextView *textView;
@end

@implementation SKFMNewFileViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"新建文件";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"创建" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(create)];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    UILabel *dirLabel = [[UILabel alloc] init];
    dirLabel.text = self.directory ?: @"";
    dirLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    dirLabel.textColor = UIColor.secondaryLabelColor;
    dirLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [stack addArrangedSubview:dirLabel];

    self.nameField = [[UITextField alloc] init];
    self.nameField.text = @"untitled.txt";
    self.nameField.placeholder = @"文件名";
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.nameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.nameField.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [self.nameField.heightAnchor constraintEqualToConstant:36].active = YES;
    [stack addArrangedSubview:self.nameField];

    UILabel *cap = [[UILabel alloc] init];
    cap.text = @"内容";
    cap.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cap.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:cap];

    self.textView = [[UITextView alloc] init];
    self.textView.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.textView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.textView.layer.cornerRadius = 10;
    self.textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [stack addArrangedSubview:self.textView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:g.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-16],
    ]];
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)create {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!name.length) {
        [self presentViewController:SKFMAlert(@"新建文件失败", @"文件名不能为空。") animated:YES completion:nil];
        return;
    }
    if ([name containsString:@"/"]) {
        [self presentViewController:SKFMAlert(@"新建文件失败", @"文件名不能包含 “/”。") animated:YES completion:nil];
        return;
    }

    NSString *dest = [self.directory stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
        [self presentViewController:SKFMAlert(@"新建文件失败", @"同名文件已存在。") animated:YES completion:nil];
        return;
    }

    NSError *err = nil;
    NSData *data = [self.textView.text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    if (!SKFMWriteData(dest, data, &err)) {
        [self presentViewController:SKFMAlert(@"新建文件失败", err.localizedDescription ?: @"写入失败")
                           animated:YES completion:nil];
        return;
    }

    SKLog(@"[fm] created file %@", dest);
    void (^cb)(NSString *) = self.onCreated;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(dest); }];
}

@end
