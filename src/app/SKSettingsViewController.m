//
//  SKSettingsViewController.m
//  AppDump — 设置
//
//  版式照官方 AppDump：EXPLOIT（VFS/SBX/Hybrid + 修改偏移）、KERNELCACHE（移除
//  内核缓存）、APP（保持后台运行 / 禁用日志分隔线 / 日志显示）、FILE MANAGER
//  （显示模式 / 递归搜索 / 在标签页中显示文件管理器）。
//

#import "SKSettingsViewController.h"
#import "SKLog.h"
#import "SKKeepAlive.h"
#import "SKOffsetsViewController.h"
#import "SKSandboxKeeper.h"
#import "offsets.h"
#import "darksword.h"
#import <objc/runtime.h>

static NSString *const kExploitMode = @"ad.exploitmode";
static NSString *const kKeepAlive   = @"ad.keepalive";
static NSString *const kNoLogSep    = @"ad.nologsep";
static NSString *const kLogDisplay  = @"ad.logdisplay";
static NSString *const kFMDisplay   = @"ad.fmdisplay";
static NSString *const kFMRecursive = @"ad.fmrecursive";
static NSString *const kFMTab       = @"ad.fmtab";

@interface SKSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISegmentedControl *exploit;
@end

@implementation SKSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(close)];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

// 「在标签页中显示文件管理器」要改 tab 数量 —— 那会替换掉正在被 sheet 覆盖的
// view controller，所以必须等设置页真正关掉再做，不能一边开着一边重建。
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SKSettingsDidDismissNotification"
                                                            object:nil];
    }
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 2;   // 模式 + 修改偏移
        case 1: return 3;   // 保持后台 / 日志分隔线 / 日志显示
        case 2: return 3;   // 显示模式 / 递归搜索 / 标签页显示
        default: return 2;  // 检查写权限 / 修复写权限
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"EXPLOIT", @"APP", @"FILE MANAGER", @"写权限" ][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"启用保持后台运行后，即使应用最小化也会继续运行。";
    if (section == 2) return @"显示模式可更改文件管理器中应用文件夹的显示方式。";
    if (section == 3) return @"沙盒策略的修改只活在内存里，写/删文件后可能被内核冲掉；"
                              @"这里可以随时检查并原地修复（只重放策略，不会重跑利用链）。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"c";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    UIListContentConfiguration *cc = [c defaultContentConfiguration];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    if (indexPath.section == 0 && indexPath.row == 0) {
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!self.exploit) {
            self.exploit = [[UISegmentedControl alloc] initWithItems:@[ @"VFS", @"SBX", @"Hybrid" ]];
            // 官方默认 Hybrid(2)：只看 VFS 或只看 SBX 是刻意的手动模式。
            self.exploit.selectedSegmentIndex = [d objectForKey:kExploitMode]
                ? [d integerForKey:kExploitMode] : 2;
            [self.exploit addTarget:self action:@selector(exploitChanged:)
                   forControlEvents:UIControlEventValueChanged];
        }
        c.accessoryView = self.exploit;
        cc.text = @"";
        c.contentConfiguration = cc;
        return c;
    }

    if (indexPath.section == 0) {
        cc.text = @"修改偏移";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cc.text = @"保持后台运行";
            c.accessoryView = [self toggleFor:kKeepAlive];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cc.text = @"禁用日志分隔线";
            c.accessoryView = [self toggleFor:kNoLogSep];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cc.text = @"日志显示";
            cc.secondaryText = [d integerForKey:kLogDisplay] == 0 ? @"In Toolbar" : @"Directly in ContentView";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cc.text = @"显示模式";
            cc.secondaryText = @[ @"App Name", @"Bundle ID", @"UUID" ][MIN((NSUInteger)2, (NSUInteger)[d integerForKey:kFMDisplay])];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            cc.text = @"文件管理器递归搜索";
            c.accessoryView = [self toggleFor:kFMRecursive];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cc.text = @"在标签页中显示文件管理器";
            c.accessoryView = [self toggleFor:kFMTab];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else {
        cc.text = indexPath.row == 0 ? @"检查写权限" : @"修复写权限";
        cc.secondaryText = indexPath.row == 0 ? [self writeAccessSummary] : nil;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    c.contentConfiguration = cc;
    return c;
}

- (UISwitch *)toggleFor:(NSString *)key {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [NSUserDefaults.standardUserDefaults boolForKey:key];
    objc_setAssociatedObject(sw, "k", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (void)toggleChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, "k");
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:key];

    // 保持后台运行是真的要开关音频会话，不能只存个值。
    if ([key isEqualToString:kKeepAlive]) SKKeepAliveSetOn(sw.on);

    [[NSNotificationCenter defaultCenter] postNotificationName:@"SKSettingsDidChangeNotification" object:nil];
}

- (void)exploitChanged:(UISegmentedControl *)seg {
    [NSUserDefaults.standardUserDefaults setInteger:seg.selectedSegmentIndex forKey:kExploitMode];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SKSettingsDidChangeNotification" object:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 1) {
        [self.navigationController pushViewController:[SKOffsetsViewController new] animated:YES];
    } else if (indexPath.section == 1 && indexPath.row == 2) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSInteger cur = [d integerForKey:kLogDisplay];
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"日志显示"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSInteger v = 0; v < 2; v++) {
            NSString *name = v == 0 ? @"In Toolbar" : @"Directly in ContentView";
            [al addAction:[UIAlertAction actionWithTitle:(v == cur ? [NSString stringWithFormat:@"✓ %@", name] : name)
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
                [d setInteger:v forKey:kLogDisplay];
                [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SKSettingsDidChangeNotification"
                                                                    object:nil];
            }]];
        }
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSInteger cur = [d integerForKey:kFMDisplay];
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"显示模式"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray<NSString *> *names = @[ @"App Name", @"Bundle ID", @"UUID" ];
        for (NSInteger v = 0; v < (NSInteger)names.count; v++) {
            [al addAction:[UIAlertAction actionWithTitle:(v == cur ? [NSString stringWithFormat:@"✓ %@", names[v]] : names[v])
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
                [d setInteger:v forKey:kFMDisplay];
                [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SKSettingsDidChangeNotification"
                                                                    object:nil];
            }]];
        }
        [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self checkWriteAccess];
        } else {
            [self confirmRepairWriteAccess];
        }
    }
}

#pragma mark - 写权限

// 不写内核、只探一次的摘要，用来填单元格右侧那行字。
- (NSString *)writeAccessSummary {
    if (!ds_is_ready()) return @"未运行利用链";
    return [SKSandboxKeeper hasPrivilegedWriteAccess] ? @"正常" : @"已丢失";
}

// 「检查写权限」：只跑探针（一次 open/write/unlink），不动内核。
- (void)checkWriteAccess {
    if (!ds_is_ready()) {
        [self alert:@"写权限" msg:@"内核读写原语未就绪。\n先在「砸壳」页运行利用链。"];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = [SKSandboxKeeper hasPrivilegedWriteAccess];
        int e = [SKSandboxKeeper writeAccessProbeErrno];
        NSString *msg = ok ? @"沙盒策略正常，/private/var/mobile 可写。"
                           : [NSString stringWithFormat:
                              @"沙盒策略已丢失（errno=%d %s）。\n点「修复写权限」原地补回来。",
                              e, strerror(e)];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self alert:@"写权限" msg:msg];
            [self.table reloadData];
        });
    });
}

- (void)confirmRepairWriteAccess {
    UIAlertController *al = [UIAlertController
        alertControllerWithTitle:@"修复写权限"
                         message:@"会通过已有的内核原语重放沙盒策略（必要时连属主一起修），"
                                  @"不会重跑利用链。继续？"
                  preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [al addAction:[UIAlertAction actionWithTitle:@"修复" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) { [weakSelf runRepairWriteAccess]; }]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)runRepairWriteAccess {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *report = [SKSandboxKeeper repairWriteAccessReportForPath:@"/private/var/mobile"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self alert:@"修复写权限" msg:report];
            [self.table reloadData];
        });
    });
}

- (void)alert:(NSString *)t msg:(NSString *)m {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:t message:m
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

@end
