//
//  SKKernelViewController.m
//  AppDump — 砸壳 tab.
//
//  版式照官方 ContentView.swift：一个 alerts section，一个 "Kernel Read Write"
//  section，行尾是状态；导航栏右侧 terminal + gear 两个按钮，gear 打开设置，
//  terminal 就地展开日志 section（不另开页面、不占 tab）。
//

#import "SKKernelViewController.h"
#import "SKAppEvents.h"
#import "SKLog.h"
#import "SKSettingsViewController.h"
#import "Exploit.h"
#import "offsets.h"
#import "darksword.h"
#import "sbx.h"
#import "vfs.h"

@interface SKKernelViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL fetching;
@property (nonatomic, assign) BOOL initializing;
@property (nonatomic, assign) BOOL hasOffsets;   // Documents/kernelcache 存在
@property (nonatomic, assign) BOOL dsReady;
@property (nonatomic, assign) BOOL sysReady;
@property (nonatomic, assign) BOOL showLogs;
@property (nonatomic, assign) BOOL inlineLogs;   // 设置里选了 Directly in ContentView
@property (nonatomic, assign) NSInteger exploitMode; // 0=VFS 1=SBX 2=Hybrid
@property (nonatomic, strong) NSTimer *logTimer;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *logButton;
@end

@implementation SKKernelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"砸壳";

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];

    [self buildToolbar];
    [self refreshStates];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStates)
                                                 name:SKExploitDidSucceedNotification
                                               object:nil];
    // 设置里删掉内核缓存后，这一页的按钮可用性要跟着变。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshStates)
                                                 name:@"SKKernelcacheDidChangeNotification"
                                               object:nil];
}

- (void)dealloc {
    [self.logTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 设置 → 日志显示：In Toolbar 时由 terminal 按钮控制，Directly in ContentView
    // 时日志 section 常驻。
    self.inlineLogs = [NSUserDefaults.standardUserDefaults integerForKey:@"ad.logdisplay"] == 1;
    [self syncLogTimer];
    [self tintLogButton];
    [self refreshStates];
}

- (BOOL)logsVisible {
    return self.showLogs || self.inlineLogs;
}

- (void)syncLogTimer {
    if ([self logsVisible]) [self startLogTimer];
    else [self stopLogTimer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

#pragma mark - toolbar

- (void)buildToolbar {
    // 官方是 terminal + gear 两个图标按钮，没有文字。
    self.logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.logButton setImage:[UIImage systemImageNamed:@"terminal"] forState:UIControlStateNormal];
    self.logButton.frame = CGRectMake(0, 0, 30, 30);
    [self.logButton addTarget:self action:@selector(toggleLogs) forControlEvents:UIControlEventTouchUpInside];

    UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
    [gear setImage:[UIImage systemImageNamed:@"gear"] forState:UIControlStateNormal];
    gear.frame = CGRectMake(0, 0, 30, 30);
    [gear addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];

    UIBarButtonItem *logItem = [[UIBarButtonItem alloc] initWithCustomView:self.logButton];
    UIBarButtonItem *gearItem = [[UIBarButtonItem alloc] initWithCustomView:gear];
    self.navigationItem.rightBarButtonItems = @[ gearItem, logItem ];
    [self tintLogButton];
}

- (void)tintLogButton {
    self.logButton.tintColor = [self logsVisible] ? UIColor.systemBlueColor : UIColor.labelColor;
}

- (void)toggleLogs {
    self.showLogs = !self.showLogs;
    [self tintLogButton];
    [self syncLogTimer];
    [self.table reloadData];
    if ([self logsVisible]) [self scrollLogsToBottom];
}

- (void)startLogTimer {
    [self.logTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.logTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) {
        [weakSelf refreshLogs];
    }];
}

- (void)stopLogTimer {
    [self.logTimer invalidate];
    self.logTimer = nil;
}

- (void)refreshLogs {
    NSArray<NSString *> *lines = SKLogRecentLines();
    // 设置 → 禁用日志分隔线：开着就紧挨着排，关掉每行之间空一行。
    BOOL compact = [NSUserDefaults.standardUserDefaults boolForKey:@"ad.nologsep"];
    NSString *text = [lines componentsJoinedByString:compact ? @"\n" : @"\n\n"];
    if (![self.logView.text isEqualToString:text]) {
        self.logView.text = text;
        [self scrollLogsToBottom];
    }
}

- (void)scrollLogsToBottom {
    if (self.logView.text.length == 0) return;
    NSRange end = NSMakeRange(self.logView.text.length - 1, 1);
    [self.logView scrollRangeToVisible:end];
}

- (void)openSettings {
    SKSettingsViewController *s = [SKSettingsViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - state

- (NSInteger)exploitModeFromDefaults {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    // 没设置过时是 Hybrid(2)：只跑 VFS 或只跑 SBX 是用户在设置里刻意选的。
    return [d objectForKey:@"ad.exploitmode"] ? [d integerForKey:@"ad.exploitmode"] : 2;
}

- (BOOL)kernelcachePresent {
    NSString *kc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                    stringByAppendingPathComponent:@"kernelcache"];
    return [[NSFileManager defaultManager] fileExistsAtPath:kc];
}

- (void)refreshStates {
    self.exploitMode = [self exploitModeFromDefaults];
    self.hasOffsets = [self kernelcachePresent];
    self.dsReady = ExploitHelper.isKernelReadable;

    // 沿用官方 SettingsView 的三种模式：VFS / SBX / Hybrid。
    if (self.exploitMode == 0) self.sysReady = vfs_isready();
    else if (self.exploitMode == 1) self.sysReady = ExploitHelper.isSandboxEscaped;
    else self.sysReady = ExploitHelper.isSandboxEscaped && vfs_isready();

    [self.table reloadData];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return [self logsVisible] ? 2 : 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // 没有 kernelcache 时**只能**取内核缓存：blade 的链依赖缓存里解析出来的偏移，
    // 拿静态表硬跑会直接把内核带崩（用户实测 panic）。
    if (section == 0) {
        if (!self.hasOffsets) return 1;                 // 获取内核缓存
        return self.dsReady ? 2 : 1;                    // 运行漏洞利用 [+ 初始化系统]
    }
    return 3;   // 日志 / 复制全部 / 清空
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"KERNEL READ WRITE" : @"LOGS";
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && indexPath.row == 0) return 240;
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && indexPath.row == 0) return [self logCell];

    static NSString *cid = @"c";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    UIListContentConfiguration *cc = [UIListContentConfiguration valueCellConfiguration];
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 1) {
        cc.text = indexPath.row == 1 ? @"复制全部" : @"清空";
        cc.textProperties.color = indexPath.row == 2 ? UIColor.systemRedColor : UIColor.systemBlueColor;
        cc.textProperties.alignment = UIListContentTextAlignmentCenter;
        c.contentConfiguration = cc;
        return c;
    }

    BOOL enabled;
    if (!self.hasOffsets) {
        cc.text = @"获取内核缓存";
        cc.secondaryText = self.fetching ? @"fetching" : @"未找到偏移，先取缓存";
        enabled = !self.fetching;
    } else if (indexPath.row == 0) {
        cc.text = @"运行漏洞利用";
        enabled = !self.running && !self.dsReady;
        cc.secondaryText = self.dsReady ? @"true" : (self.running ? @"running" : @"false");
    } else {
        cc.text = self.exploitMode == 0 ? @"初始化 VFS"
                : self.exploitMode == 1 ? @"逃逸沙盒"
                                        : @"初始化系统";
        cc.secondaryText = self.sysReady ? @"true" : (self.initializing ? @"running" : @"false");
        enabled = !self.sysReady && !self.initializing && !self.running;
    }
    cc.textProperties.color = enabled ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    cc.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    cc.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.contentConfiguration = cc;
    c.userInteractionEnabled = enabled;
    c.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)logCell {
    static NSString *lid = @"log";
    UITableViewCell *c = [self.table dequeueReusableCellWithIdentifier:lid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:lid];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
        tv.editable = NO;
        tv.selectable = YES;
        tv.scrollEnabled = YES;
        tv.backgroundColor = UIColor.clearColor;
        tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        tv.textColor = UIColor.secondaryLabelColor;
        tv.textContainerInset = UIEdgeInsetsMake(4, 6, 4, 6);
        tv.translatesAutoresizingMaskIntoConstraints = NO;
        [c.contentView addSubview:tv];
        [NSLayoutConstraint activateConstraints:@[
            [tv.leadingAnchor constraintEqualToAnchor:c.contentView.leadingAnchor],
            [tv.trailingAnchor constraintEqualToAnchor:c.contentView.trailingAnchor],
            [tv.topAnchor constraintEqualToAnchor:c.contentView.topAnchor],
            [tv.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor],
        ]];
        self.logView = tv;
        [self refreshLogs];
        dispatch_async(dispatch_get_main_queue(), ^{ [self scrollLogsToBottom]; });
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 1) {
        if (indexPath.row == 1) {                       // 复制全部
            UIPasteboard.generalPasteboard.string = [SKLogRecentLines() componentsJoinedByString:@"\n"];
        } else if (indexPath.row == 2) {                // 清空（row 0 是日志框，点它不该清空）
            SKLogClearRecentLines();
            [self refreshLogs];
        }
        return;
    }
    if (indexPath.section != 0) return;

    if (!self.hasOffsets) { [self fetchKernelcache]; return; }
    if (indexPath.row == 0) [self runExploit];
    else [self initializeSystem];
}

#pragma mark - actions

- (void)fetchKernelcache {
    if (self.hasOffsets || self.fetching || self.running || self.dsReady) return;
    self.fetching = YES;
    [self.table reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = dlkcache();
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.fetching = NO;
            if (!ok) SKLog(@"[kc] kernelcache acquisition failed");
            [weakSelf refreshStates];
        });
    });
}

- (void)runExploit {
    // 没有内核缓存 -> 偏移是 0，跑链必炸。这里直接挡住，不去赌。
    if (!self.hasOffsets) {
        SKLog(@"[ds] refusing to run: no kernelcache (offsets unresolved)");
        [self fetchKernelcache];
        return;
    }
    // 一次只跑一条链：已经在跑、或者已经建立了会话，都不再进。
    if (self.running || self.dsReady) return;

    self.running = YES;
    [self.table reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [ExploitHelper runExploitWithLog:^(NSString *line) { SKLog(@"[ds] %@", line); }];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.running = NO;
            weakSelf.dsReady = ok;
            [weakSelf refreshStates];
            if (ok)
                [NSNotificationCenter.defaultCenter postNotificationName:SKExploitDidSucceedNotification
                                                                  object:nil];
        });
    });
}

- (void)initializeSystem {
    if (!self.dsReady || self.initializing || self.running) return;

    self.initializing = YES;
    [self.table reloadData];
    __weak typeof(self) weakSelf = self;
    NSInteger mode = self.exploitMode;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (mode != 0 && ds_is_ready()) {
            uint64_t p = ds_get_our_proc();
            if (p) sbx_escape(p);
        }
        if (mode != 1) vfs_init();
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.initializing = NO;
            [weakSelf refreshStates];
        });
    });
}

@end
