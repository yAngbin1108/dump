//
//  SKPermsEditor.m
//  Blade — 可视化权限编辑器
//

#import "SKPermsEditor.h"
#import "SKLoc.h"
#import "SKLog.h"
#import "apfs.h"
#import "darksword.h"
#import "SKKernelLock.h"

#include <sys/stat.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// r/w/x 的位定义，按 所有者/组/其他 三组排列
typedef struct {
    unsigned r, w, x;
} SKPermTriple;

static const SKPermTriple kTriples[3] = {
    { S_IRUSR, S_IWUSR, S_IXUSR },
    { S_IRGRP, S_IWGRP, S_IXGRP },
    { S_IROTH, S_IWOTH, S_IXOTH },
};

static NSString *SKLocRow(NSInteger group, NSInteger row) {
    if (row == 0) return SKLoc(@"fm.perm.read");
    if (row == 1) return SKLoc(@"fm.perm.write");
    return SKLoc(@"fm.perm.exec");
}

@interface SKPermsEditor () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, assign) unsigned int mode;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *octalLabel;
@property (nonatomic, strong) NSMutableArray<UISwitch *> *switches;  // 12 个：9 普通 + 3 特殊
@end

@implementation SKPermsEditor

- (instancetype)initWithPath:(NSString *)path mode:(unsigned int)mode {
    return [self initWithPath:path mode:mode isDir:NO];
}

- (instancetype)initWithPath:(NSString *)path mode:(unsigned int)mode isDir:(BOOL)isDir {
    self = [super init];
    if (self) {
        _path = [path copy];
        _mode = mode & 07777;
        _isDir = isDir;
        _switches = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 标题实时显示八进制，改一个开关就更新
    self.octalLabel = [[UILabel alloc] init];
    self.octalLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightSemibold];
    self.octalLabel.textAlignment = NSTextAlignmentCenter;
    self.octalLabel.textColor = [UIColor labelColor];
    [self.octalLabel sizeToFit];
    self.navigationItem.titleView = self.octalLabel;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:SKLoc(@"fm.perm.apply")
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(applyTapped)];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 48;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    [self rebuildSwitches];
    [self refreshOctal];
}

// 12 个开关一次建好，之后一直复用；每个 tag = 组的索引，特殊位用负数区分。
- (void)rebuildSwitches {
    [self.switches removeAllObjects];
    for (int g = 0; g < 3; g++) {
        for (int r = 0; r < 3; r++) {
            UISwitch *sw = [[UISwitch alloc] init];
            sw.onTintColor = [UIColor systemBlueColor];
            sw.tag = g * 3 + r;                      // 0..8 普通位
            sw.on = (self.mode & [self bitForGroup:g row:r]) != 0;
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            [self.switches addObject:sw];
        }
    }
    const unsigned specials[3] = { S_ISUID, S_ISGID, S_ISVTX };
    for (int i = 0; i < 3; i++) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.onTintColor = [UIColor systemOrangeColor];
        sw.tag = 100 + i;                            // 特殊位
        sw.on = (self.mode & specials[i]) != 0;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [self.switches addObject:sw];
    }
}

- (unsigned)bitForGroup:(NSInteger)g row:(NSInteger)r {
    SKPermTriple t = kTriples[g];
    return r == 0 ? t.r : (r == 1 ? t.w : t.x);
}

- (void)switchChanged:(UISwitch *)sw {
    if (sw.tag >= 100) {
        const unsigned specials[3] = { S_ISUID, S_ISGID, S_ISVTX };
        unsigned bit = specials[sw.tag - 100];
        if (sw.on) self.mode |= bit; else self.mode &= ~bit;
    } else {
        NSInteger g = sw.tag / 3, r = sw.tag % 3;
        unsigned bit = [self bitForGroup:g row:r];
        if (sw.on) self.mode |= bit; else self.mode &= ~bit;
    }
    [self refreshOctal];
}

- (void)refreshOctal {
    self.octalLabel.text = [NSString stringWithFormat:@"%04o", self.mode];
    [self.octalLabel sizeToFit];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return SKLoc(@"fm.perm.special");
        case 1: return SKLoc(@"fm.perm.owner");
        case 2: return SKLoc(@"fm.perm.group");
        default: return SKLoc(@"fm.perm.other");
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 0 ? self.path : nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 3 : 3;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"permcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.onTintColor = [UIColor systemBlueColor];
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    NSInteger idx;
    if (ip.section == 0) {
        static const char *names[3] = { "setuid", "setgid", "sticky" };
        cell.textLabel.text = [NSString stringWithFormat:@"%s", names[ip.row]];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
        idx = 9 + ip.row;
    } else {
        cell.textLabel.text = SKLocRow(ip.section, ip.row);
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        idx = (ip.section - 1) * 3 + ip.row;
    }
    sw.tag = (ip.section == 0) ? (100 + ip.row) : (NSInteger)idx;
    // 用当前 mode 重新同步，避免复用时显示错位
    if (ip.section == 0) {
        const unsigned specials[3] = { S_ISUID, S_ISGID, S_ISVTX };
        sw.on = (self.mode & specials[ip.row]) != 0;
    } else {
        sw.on = (self.mode & [self bitForGroup:(ip.section - 1) row:ip.row]) != 0;
    }
    return cell;
}

#pragma mark - actions

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)applyTapped {
    // 不可变标志位会直接让 chmod 失败，先清掉
    [[NSFileManager defaultManager] setAttributes:@{NSFileImmutable: @(NO)}
                                     ofItemAtPath:self.path
                                            error:nil];

    const char *cp = self.path.fileSystemRepresentation;

    errno = 0;
    BOOL ok = (chmod(cp, (mode_t)self.mode) == 0);
    int firstErr = errno;

    if (!ok && ds_is_ready()) {
        // chmod() 走 vnode_authorize：即便属主已经是我们自己，iOS 仍可能因为
        // vnode 上的 restricted 标志、或沙盒的 file-write-mode 检查把它拒掉
        // （设备日志里就是 "chmod -> 0777 failed: Operation not permitted"）。
        // 内核路径直接写 APFS inode 的 mode 字段，这两道都绕开。
        printf("[perms] chmod %s -> %04o 被拒 (%s)，改用内核路径\n",
               cp, self.mode, strerror(firstErr));
        [SKKernelLock() lock];
        @try {
            // 必须带类型位：fsnode.mode 存的是完整 16 位，只给 07777 会把
            // S_IFDIR/S_IFREG 抹掉（apfs_mod 内部也会兜底，但这里显式给更清楚）
            struct stat cur;
            mode_t type = 0;
            if (stat(cp, &cur) == 0) type = (cur.st_mode & S_IFMT);
            if (type == 0) type = self.isDir ? S_IFDIR : S_IFREG;   // 修复历史损坏
            mode_t full = (mode_t)(type | (self.mode & 07777));
            ok = (apfs_mod(cp, full) == 0);
        } @catch (NSException *ex) {
            printf("[perms] apfs_mod 抛异常: %s\n", ex.reason.UTF8String);
            ok = NO;
        } @finally {
            [SKKernelLock() unlock];
        }
        if (ok) {
            // apfs_mod 自己已经回读校验过，这里再用 stat 确认一次
            struct stat st;
            ok = (stat(cp, &st) == 0) && ((st.st_mode & 07777) == (self.mode & 07777));
        }
    }

    if (!ok) {
        int e = firstErr ? firstErr : errno;
        printf("[perms] chmod %s -> %04o 最终失败: %s\n", cp, self.mode, strerror(e));
        SKLog(@"[perms] chmod %@ -> %04o failed: %s", self.path, self.mode, strerror(e));
        UIAlertController *a = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.perms.failed")
                                                                  message:[NSString stringWithFormat:@"%s", strerror(e)]
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    printf("[perms] chmod %s -> %04o ok\n", cp, self.mode);
    SKLog(@"[perms] chmod %@ -> %04o ok", self.path, self.mode);
    if (self.onApplied) self.onApplied(self.mode);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
