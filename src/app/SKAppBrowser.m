//
//  SKAppBrowser.m
//  SandboxKit — installed-app browser
//

#import "SKAppBrowser.h"
#import "SKAppEvents.h"
#import "SKLoc.h"
#import "SKDecryptUI.h"
#import "SKLaraFileBrowser.h"
#import "SKOverlay.h"
#import "SKLog.h"
#import "kcblock.h"
#import "decrypt.h"
#import "kexploit/utils.h"

#include <sys/stat.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSString * const kBundleRoot       = @"/var/containers/Bundle/Application";
// 系统应用不在 /var/containers 下：iOS 14+ 在 /System/Applications 与
// /private/var/staged_system_apps，老系统在 /Applications。只扫 kBundleRoot
// 会漏掉一大批（设置、Safari、快捷指令…），所以四个根都扫。
static NSArray<NSString *> *SKAppBundleRoots(void) {
    return @[ @"/var/containers/Bundle/Application",
              @"/Applications",
              @"/System/Applications",
              @"/private/var/staged_system_apps" ];
}
static NSString * const kDataRoot         = @"/var/mobile/Containers/Data/Application";
static NSString * const kAppGroupRoot     = @"/var/mobile/Containers/Shared/AppGroup";
static NSString * const kMetadataFile     = @".com.apple.mobile_container_manager.metadata.plist";

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Model
// ─────────────────────────────────────────────────────────────────────────────

@interface SKInstalledApp : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, copy) NSString *executable;
@property (nonatomic, copy, nullable) NSString *dataPath;
@property (nonatomic, copy, nullable) NSString *groupPath;
/// 是否系统应用（/System/Applications 等根下）。
@property (nonatomic, assign) BOOL isSystem;
/// 扫描阶段渲染好的图标，cellForRow 直接赋值用。
@property (nonatomic, strong, nullable) UIImage *icon;
@end

@implementation SKInstalledApp
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Icon helper
// ─────────────────────────────────────────────────────────────────────────────

// A neutral placeholder so rows never collapse when an app ships no icon we
// can read. Drawn rather than loaded, so there is no asset dependency.
static UIImage *SKPlaceholderIcon(CGFloat side) {
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect b = CGRectMake(0, 0, side, side);
        [[UIColor colorWithWhite:0.78 alpha:1.0] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:b cornerRadius:side * 0.225] fill];

        // Faint grid, echoing the system's generic app icon.
        [[UIColor colorWithWhite:0.62 alpha:1.0] setStroke];
        UIBezierPath *p = [UIBezierPath bezierPath];
        p.lineWidth = 1.0;
        for (int i = 1; i < 3; i++) {
            CGFloat f = side * (CGFloat)i / 3.0;
            [p moveToPoint:CGPointMake(f, side * 0.16)];
            [p addLineToPoint:CGPointMake(f, side * 0.84)];
            [p moveToPoint:CGPointMake(side * 0.16, f)];
            [p addLineToPoint:CGPointMake(side * 0.84, f)];
        }
        [p stroke];
    }];
}

// 把任意尺寸的图片重绘成 pt×pt 点（像素由 screen scale 决定）。
//
// 磁盘上的图标是 60/120/180 像素，UIImage 按 scale=1 读进来就是 60/120/180 **点**，
// 而行高只有 64 点 → 图标溢出到相邻行。必须按点尺寸重绘。
static UIImage *SKScaledIcon(UIImage *raw, CGFloat pt) {
    if (!raw) return nil;
    if (fabs(raw.size.width - pt) < 0.5 && fabs(raw.size.height - pt) < 0.5) return raw;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = UIScreen.mainScreen.scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pt, pt) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [raw drawInRect:CGRectMake(0, 0, pt, pt)];
    }];
}

// 系统应用的图标不在 bundle 里的 png，而在共享缓存/Assets.car 里，只能问系统要。
// LSApplicationProxy 的 _applicationIconImageForFormat:scale: 是现成的入口。
static UIImage *SKIconViaLS(NSString *bundleID, CGFloat side) {
    static Class proxyCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *mcs = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        if (!mcs) mcs = dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        proxyCls = NSClassFromString(@"LSApplicationProxy");
    });
    if (!proxyCls || !bundleID.length) return nil;

    UIImage *img = nil;
    @try {
        SEL mk = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (![proxyCls respondsToSelector:mk]) return nil;
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyCls, mk, bundleID);
        if (!proxy) return nil;

        SEL iconSel = NSSelectorFromString(@"iconForInterfaceStyle");
        if ([proxy respondsToSelector:iconSel]) {
            id r = ((id (*)(id, SEL))objc_msgSend)(proxy, iconSel);
            if ([r isKindOfClass:UIImage.class]) img = r;
        }
        if (!img) {
            SEL s2 = NSSelectorFromString(@"_applicationIconImageForFormat:scale:");
            if ([proxy respondsToSelector:s2]) {
                id r = ((id (*)(id, SEL, long, double))objc_msgSend)(proxy, s2, 0, 0.0);
                if ([r isKindOfClass:UIImage.class]) img = r;
            }
        }
    } @catch (NSException *e) {
        img = nil;
    }
    return img ? SKScaledIcon(img, side) : nil;
}

static UIImage *SKIconForApp(NSString *bundlePath, NSDictionary *info, CGFloat side) {
    // Preferred: the modern named-icon keys.
    NSArray *names = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
    if (![names isKindOfClass:NSArray.class]) {
        names = info[@"CFBundleIconFiles"];
    }

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *n in names) {
        if (![n isKindOfClass:NSString.class]) continue;
        [candidates addObject:n];
        // The plain name usually has no extension on disk; try the @2x/@3x forms.
        [candidates addObject:[n stringByAppendingString:@"@2x"]];
        [candidates addObject:[n stringByAppendingString:@"@3x"]];
    }
    // Classic fallbacks.
    [candidates addObjectsFromArray:@[ @"AppIcon60x60@2x", @"AppIcon60x60@3x",
                                       @"Icon", @"Icon@2x", @"Icon-60@2x" ]];

    for (NSString *c in candidates) {
        for (NSString *ext in @[ @"", @".png" ]) {
            NSString *p = [bundlePath stringByAppendingPathComponent:
                           [c stringByAppendingString:ext]];
            UIImage *img = [UIImage imageWithContentsOfFile:p];
            if (img) return img;
        }
    }
    return SKPlaceholderIcon(side);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Browser
// ─────────────────────────────────────────────────────────────────────────────

@interface SKAppBrowserViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISwitch *systemSwitch;   // 顶部滑块：显示内建 App
@property (nonatomic, copy) NSString *query;
- (void)rebuildFiltered;
- (BOOL)showSystemApps;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<SKInstalledApp *> *apps;
@property (nonatomic, strong) NSArray<SKInstalledApp *> *filtered;

// Injected SpringBoard overlay.
@property (nonatomic, strong) NSTimer *overlayTimer;
@property (nonatomic, strong) NSArray<NSDictionary *> *overlayProcs;
@property (nonatomic, assign) BOOL overlayPollBusy;
@end

@implementation SKAppBrowserViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SKLoc(@"apps.title");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = (id)self;
    self.searchBar.placeholder = SKLoc(@"apps.search");
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 64;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];

    // 应用列表的搜索栏也没有取消按钮，点列表空白处收键盘。
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(dismissKeyboard:)];
    tap.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:tap];

    // 顶部滑块：显示 / 不显示内建（系统）App。默认关闭 —— 只显示 App Store
    // 和侧载的应用；打开则连 /System/Applications 那些一起列出来。
    self.systemSwitch = [[UISwitch alloc] init];
    self.systemSwitch.on = [NSUserDefaults.standardUserDefaults boolForKey:@"ad.showsystemapps"];
    [self.systemSwitch addTarget:self action:@selector(systemSwitchChanged:)
                forControlEvents:UIControlEventValueChanged];

    UILabel *sysLabel = [[UILabel alloc] init];
    sysLabel.text = @"显示内建 App";
    sysLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    sysLabel.textColor = UIColor.secondaryLabelColor;
    sysLabel.tag = 9001;
    [self.view addSubview:sysLabel];
    [self.view addSubview:self.systemSwitch];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    UIBarButtonItem *refresh =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];
    // The RemoteCall floating-ball entry point is deliberately not exposed.
    // RemoteCall needs an arm64e launch context, and every arm64e build we
    // shipped has failed to load on device; leaving a button that can only ever
    // produce an error is worse than not having it. The SKOverlay implementation
    // is still here and can be re-enabled by putting the item back:
    //
    //   UIBarButtonItem *ball =
    //       [[UIBarButtonItem alloc] initWithTitle:SKLoc(@"overlay.title")
    //                                       style:UIBarButtonItemStylePlain
    //                                      target:self action:@selector(toggleOverlay)];
    //   self.navigationItem.rightBarButtonItems = @[ refresh, ball ];
    self.navigationItem.rightBarButtonItems = @[ refresh ];

    // 利用成功后自动刷新一次：之前列表是在 viewDidLoad 里扫的，跑完利用
    // 回来还是那份旧数据，必须手动点刷新。
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleRefreshNotification:)
                                               name:SKExploitDidSucceedNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(handleRefreshNotification:)
                                               name:SKDumpDidFinishNotification
                                             object:nil];

    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.apps.count && !self.spinner.isAnimating) [self reload];
}

- (void)handleRefreshNotification:(NSNotification *)note {
    [self reload];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat top = self.view.safeAreaInsets.top, bot = self.view.safeAreaInsets.bottom;
    const CGFloat kSwitchRow = 36.0;
    UILabel *sysLabel = [self.view viewWithTag:9001];
    sysLabel.frame = CGRectMake(16, top, w - 16 - 60, kSwitchRow);
    self.systemSwitch.frame = CGRectMake(w - 16 - self.systemSwitch.bounds.size.width,
                                         top + (kSwitchRow - self.systemSwitch.bounds.size.height) / 2,
                                         self.systemSwitch.bounds.size.width,
                                         self.systemSwitch.bounds.size.height);
    CGFloat listTop = top + kSwitchRow;
    self.searchBar.frame = CGRectMake(0, listTop, w, 50);
    // 铺到屏幕最底边，底部安全区用 contentInset 补，否则会露出一条背景色空条
    self.tableView.frame = CGRectMake(0, listTop + 50, w, h - (listTop + 50));
    // 底部多让 5pt，列表最后一行不会贴住底栏边缘。
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, bot + 5, 0);
    self.tableView.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bot + 5, 0);
    self.spinner.center = CGPointMake(w / 2, h / 2);
}

- (void)reload {
    [self.spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = [self scan];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            [self rebuildFiltered];      // 搜索词 / 内建 App 开关都在这里统一处理
            [self.spinner stopAnimating];
        });
    });
}

// ── container lookup ───────────────────────────────────────────────────────
// 每个根目录只遍历一次，建 identifier → 容器路径 的字典。
//
// 原来是「每个 app 都遍历一遍容器根目录、逐个读 metadata plist」，
// 79 个应用 × 约 100 个容器 × 2 次（data + group）≈ 一万五千次 plist 读取，
// 这就是列表加载慢的主因。
static NSDictionary<NSString *, NSString *> *SKBuildContainerIndex(NSString *root) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *dir = [root stringByAppendingPathComponent:uuid];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                           [dir stringByAppendingPathComponent:kMetadataFile]];
        NSString *ident = d[@"MCMMetadataIdentifier"];
        if (ident.length && !map[ident]) map[ident] = dir;
    }
    return map;
}

- (NSArray<SKInstalledApp *> *)scan {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *out = [NSMutableArray array];
    NSString *selfID = NSBundle.mainBundle.bundleIdentifier;

    NSDictionary *dataIndex  = SKBuildContainerIndex(kDataRoot);
    NSDictionary *groupIndex = SKBuildContainerIndex(kAppGroupRoot);

    // 图标统一按 40pt 渲染一次（不是 120 点！见 SKScaledIcon 的注释）
    const CGFloat kIconSide = 40.0;

    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // (bundle 路径, Info.plist, 是否系统应用)
    NSMutableArray<NSArray *> *bundles = [NSMutableArray array];
    // ① 用户 App：/var/containers/Bundle/Application/<uuid>/<Name>.app
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:kBundleRoot error:NULL]) {
        NSString *dir = [kBundleRoot stringByAppendingPathComponent:uuid];
        for (NSString *bn in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![bn hasSuffix:@".app"]) continue;
            NSString *bp = [dir stringByAppendingPathComponent:bn];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [bp stringByAppendingPathComponent:@"Info.plist"]];
            if (info) [bundles addObject:@[ bp, info, @NO ]];
        }
    }
    // ② 系统应用：三个根，直接一层 <Name>.app
    for (NSString *root in SKAppBundleRoots()) {
        if ([root isEqualToString:kBundleRoot]) continue;
        for (NSString *bn in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            if (![bn hasSuffix:@".app"]) continue;
            NSString *bp = [root stringByAppendingPathComponent:bn];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [bp stringByAppendingPathComponent:@"Info.plist"]];
            if (info) [bundles addObject:@[ bp, info, @YES ]];
        }
    }

    for (NSArray *item in bundles) {
        @autoreleasepool {
            NSString *bp = item[0];
            NSDictionary *info = item[1];
            BOOL isSystem = [item[2] boolValue];
            NSString *bid  = info[@"CFBundleIdentifier"];
            NSString *exec = info[@"CFBundleExecutable"];
            if (!bid.length || !exec.length) continue;
            if (selfID && [bid isEqualToString:selfID]) continue;
            if ([seen containsObject:bid]) continue;      // 同一个 App 出现在两个根里只留一份
            [seen addObject:bid];

            SKInstalledApp *a = [SKInstalledApp new];
            a.bundleID   = bid;
            a.bundlePath = bp;
            a.executable = exec;
            a.name       = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"]
                           ?: bp.lastPathComponent.stringByDeletingPathExtension;
            a.dataPath   = dataIndex[bid];
            a.groupPath  = groupIndex[[@"group." stringByAppendingString:bid]];
            a.isSystem   = isSystem;

            UIImage *icon = SKIconForApp(bp, info, kIconSide);
            if (!icon) icon = SKIconViaLS(bid, kIconSide);   // 系统应用走这条路
            a.icon = icon ? SKScaledIcon(icon, kIconSide) : SKPlaceholderIcon(kIconSide);
            [out addObject:a];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(SKInstalledApp *x, SKInstalledApp *y) {
        return [x.name caseInsensitiveCompare:y.name];
    }];
    return out;
}

// ── table ──────────────────────────────────────────────────────────────────
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.filtered.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"app";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];

    SKInstalledApp *a = self.filtered[ip.row];
    c.textLabel.text = a.name;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = a.isSystem ? [NSString stringWithFormat:@"%@ · 系统", a.bundleID]
                                        : a.bundleID;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // 图标已在 scan 阶段渲染好；这里只赋值。
    c.imageView.image = a.icon;
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;
    c.imageView.layer.cornerRadius = 9;
    c.imageView.clipsToBounds = YES;
    return c;
}


// ── 限制某个 App 访问 Keychain（不动文件）───────────────────────────────────
// 内核侧只把目标进程 sandbox label 里指向 securityd / Keychains 的那几条
// extension 摘掉：它的 SecItem* 之后会在 mach-lookup / 文件检查阶段被内核拒掉，
// 磁盘不动，其它 App 不受影响。目标必须在运行。
static dispatch_source_t gKcTimer = nil;
static pid_t gKcTimerPid = 0;

- (void)kcWatchdogStart:(pid_t)pid {
    if (gKcTimer) { dispatch_source_cancel(gKcTimer); gKcTimer = nil; }
    gKcTimerPid = pid;
    gKcTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                      dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(gKcTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              150ull * NSEC_PER_MSEC, 50ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gKcTimer, ^{
        char r[512] = {0};
        int n = kcblock_port_block(gKcTimerPid, r, sizeof(r));
        if (n > 0) SKLog(@"[kcblock] watchdog cleared %d\n%s", n, r);
    });
    dispatch_resume(gKcTimer);
    SKLog(@"[kcblock] watchdog started for pid %d", pid);
}

- (void)kcWatchdogStop {
    if (!gKcTimer) return;
    dispatch_source_cancel(gKcTimer);
    gKcTimer = nil;
    SKLog(@"[kcblock] watchdog stopped");
}

- (void)keychainActionForApp:(SKInstalledApp *)a apply:(BOOL)apply {
    pid_t pid = a.executable.length ? find_process_pid(a.executable.UTF8String) : -1;
    if (pid <= 0) {
        [self toast:@"该 App 没在运行：先打开它再操作"];
        return;
    }
    char report[4096] = {0};
    int n = apply ? kcblock_apply(pid, report, sizeof(report))
                  : kcblock_restore(pid, report, sizeof(report));
    if (apply) {
        // 不管 extension 层有没有命中，都再做一次端口层（真正拦 keychain 的那层）
        char ports[3072] = {0};
        int pn = kcblock_port_block(pid, ports, sizeof(ports));
        if (pn > 0) n += pn;
        strncat(report, "\n", sizeof(report) - strlen(report) - 1);
        strncat(report, ports, sizeof(report) - strlen(report) - 1);
    }
    if (apply && n == 0) {
        // 这台机器上 keychain 权限不在 sandbox extension 里：把 ipc namespace 的
        // port 情况一并打出来，下一步按端口拦截。
        char ports[3072] = {0};
        kcblock_port_scan(pid, ports, sizeof(ports));
        strncat(report, "\n", sizeof(report) - strlen(report) - 1);
        strncat(report, ports, sizeof(report) - strlen(report) - 1);
    }
    SKLog(@"[kcblock] %@ %@ pid=%d -> %d\n%s", a.bundleID,
          apply ? @"block" : @"restore", pid, n, report);
    if (apply) [self kcWatchdogStart:pid]; else [self kcWatchdogStop];
    NSString *msg = [NSString stringWithFormat:@"%@\n%s",
                     (n > 0 ? (apply ? @"已阻断 keychain" : @"已恢复 keychain") : @"没有找到可处理的条目"),
                     report];
    [self toast:msg];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    SKInstalledApp *a = self.filtered[ip.row];

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:a.name message:a.bundleID
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [sheet addAction:[UIAlertAction actionWithTitle:SKLoc(@"apps.menu.bundle")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [weakSelf browse:a.bundlePath title:SKLoc(@"apps.dir.bundle")];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:SKLoc(@"apps.menu.group")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (a.groupPath) [weakSelf browse:a.groupPath title:SKLoc(@"apps.dir.group")];
        else [weakSelf toast:SKLoc(@"apps.no.group")];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:SKLoc(@"apps.menu.data")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (a.dataPath) [weakSelf browse:a.dataPath title:SKLoc(@"apps.dir.data")];
        else [weakSelf toast:SKLoc(@"apps.no.data")];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:SKLoc(@"apps.menu.decrypt")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [weakSelf decryptApp:a];
    }]];



    [sheet addAction:[UIAlertAction actionWithTitle:@"限制 Keychain"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [weakSelf keychainActionForApp:a apply:YES];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"解除 Keychain 限制"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [weakSelf keychainActionForApp:a apply:NO];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = tv;
    sheet.popoverPresentationController.sourceRect = [tv rectForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

// ── injected overlay ──────────────────────────────────────────────────────
//
// Every RemoteCall operation runs on `overlayQueue`, a serial background
// queue. A single remote_msg is a Mach round trip through SpringBoard's
// exception ports, so running a few dozen of them on the main thread visibly
// freezes this app — and the panel build is hundreds of them.
//
// The 50 ms timer only *hands work* to that queue and skips a tick while the
// previous one is still running, so a slow SpringBoard can never build up a
// backlog of pending polls.

- (dispatch_queue_t)overlayQueue {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.appdump.overlay", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

- (void)toggleOverlay {
    SKOverlay *ov = [SKOverlay shared];
    __weak typeof(self) weakSelf = self;

    if (ov.running) {
        [self.overlayTimer invalidate];
        self.overlayTimer = nil;
        SKLog(@"overlay: disable requested");
        dispatch_async(self.overlayQueue, ^{
            [ov stop];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf toast:SKLoc(@"apps.ball.off")];
            });
        });
        return;
    }

    SKLog(@"overlay: enable requested");
    __weak SKOverlay *weakOv = ov;
    dispatch_async(self.overlayQueue, ^{
        NSString *err = [weakOv start];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self_ = weakSelf;
            if (!self_) return;
            if (err) { [self_ showDiagnostic:err]; return; }
            [self_ toast:SKLoc(@"apps.ball.on")];
            [self_ startOverlayPolling];
        });
    });
}

- (void)startOverlayPolling {
    if (self.overlayTimer) return;
    __weak typeof(self) weakSelf = self;
    self.overlayTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;
        if (self_.overlayPollBusy) return;          // previous poll still running
        self_.overlayPollBusy = YES;

        dispatch_async(self_.overlayQueue, ^{
            [[SKOverlay shared] pollWithHandler:^(SKOverlayEvent event, NSInteger rowIndex, CGFloat value) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self2 = weakSelf;
                    if (!self2) return;
                    if (event == SKOverlayEventBallTapped) {
                        [self2 overlayBallTapped];
                    } else if (event == SKOverlayEventRowTapped) {
                        [self2 overlayRowTapped:rowIndex];
                    }
                });
            }];
            self_.overlayPollBusy = NO;
        });
    }];
}

// Main thread: decide, then hand the remote work to the serial queue.
- (void)overlayBallTapped {
    SKOverlay *ov = [SKOverlay shared];
    if (ov.panelOpen) {
        dispatch_async(self.overlayQueue, ^{
            [ov hidePanel];
            SKLog(@"overlay: panel hidden");
        });
        return;
    }
    [self refreshOverlayProcessList];
}

// Must be called on overlayQueue (it blocks on hundreds of round trips).
- (void)refreshOverlayProcessListLocked {
    double t0 = CFAbsoluteTimeGetCurrent();
    int count = 0;
    proc_entry_t *list = proclist(NULL, &count);
    NSMutableArray *procs = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    if (list && count > 0) {
        for (int i = 0; i < count && i < 100; i++) {
            NSString *name = [NSString stringWithUTF8String:list[i].name] ?: @"";
            [procs addObject:@{ @"pid": @(list[i].pid), @"name": name }];
            [labels addObject:[NSString stringWithFormat:@"%d  %@", list[i].pid, name]];
        }
        free_proclist(list);
    }
    SKLog(@"overlay: proclist returned %d entries, using %lu",
          count, (unsigned long)procs.count);

    self.overlayProcs = procs;
    [[SKOverlay shared] showPanelWithTitle:SKLoc(@"apps.menu.processes") rows:labels];

    double dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    SKLog(@"overlay: panel refreshed in %.0fms (%lu rows)", dt, (unsigned long)procs.count);
}

- (void)refreshOverlayProcessList {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.overlayQueue, ^{
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;
        [self_ refreshOverlayProcessListLocked];
    });
}

- (void)overlayRowTapped:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.overlayProcs.count) return;
    NSDictionary *p = self.overlayProcs[index];
    SKLog(@"overlay: row %ld tapped -> %@ (pid %@)",
          (long)index, p[@"name"], p[@"pid"]);

    // Stage 1: surface the selection. The in-overlay modifier page is next —
    // it must be drawn inside the overlay, not with a native UIAlertController.
    SKOverlay *ov = [SKOverlay shared];
    dispatch_async(self.overlayQueue, ^{
        [ov showPanelWithTitle:[NSString stringWithFormat:@"%@ (PID %@)", p[@"name"], p[@"pid"]]
                          rows:@[SKLoc(@"proc.menu.readMem"), SKLoc(@"proc.menu.writeMem"), SKLoc(@"apps.menu.modules"), SKLoc(@"common.back")]];
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.overlayTimer) {
        [self.overlayTimer invalidate];
        self.overlayTimer = nil;
    }
}

- (void)browse:(NSString *)path title:(NSString *)title {
    SKLaraFileBrowser *b = [[SKLaraFileBrowser alloc] initWithPath:path];
    b.title = title;
    [self.navigationController pushViewController:b animated:YES];
}

- (void)decryptApp:(SKInstalledApp *)a {
    SKDecryptRunnerViewController *r =
        [[SKDecryptRunnerViewController alloc] initWithAppName:a.name
                                                      bundleID:a.bundleID
                                                    bundlePath:a.bundlePath
                                                    executable:a.executable];
    [self.navigationController pushViewController:r animated:YES];
}

- (void)toast:(NSString *)msg {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:nil message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

// A UIAlertController silently clips long multi-line messages, which is exactly
// what a diagnosis is. Present it in a full-screen, scrollable, selectable text
// view instead so nothing can be lost.
- (void)showDiagnostic:(NSString *)text {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    vc.title = SKLoc(@"apps.menu.ballDiag");

    UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.text = text;
    tv.textColor = UIColor.labelColor;
    tv.backgroundColor = UIColor.systemBackgroundColor;
    [vc.view addSubview:tv];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    vc.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:SKLoc(@"common.ok")
                                         style:UIBarButtonItemStyleDone
                                        target:self action:@selector(dismissDiagnostic)];
    [self presentViewController:nav animated:YES completion:nil];

    // Also mirror to the log so the host can read it over SSH.
    SKLog(@"=== DIAGNOSTIC ===\n%@\n=== END DIAGNOSTIC ===", text);
}

- (void)dismissDiagnostic {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// ── search ─────────────────────────────────────────────────────────────────
@interface SKAppBrowserViewController (Search) <UISearchBarDelegate>
@end
@implementation SKAppBrowserViewController (Search)
- (void)dismissKeyboard:(UIGestureRecognizer *)g {
    if (self.searchBar.isFirstResponder) {
        [self.searchBar resignFirstResponder];
        [self.view endEditing:YES];
    }
}

- (BOOL)showSystemApps {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"ad.showsystemapps"];
}

// 列表 = 全部 App（可选排除内建）+ 搜索词过滤
- (void)rebuildFiltered {
    NSArray<SKInstalledApp *> *base = self.apps ?: @[];
    if (![self showSystemApps]) {
        NSMutableArray *userOnly = [NSMutableArray array];
        for (SKInstalledApp *a in base) if (!a.isSystem) [userOnly addObject:a];
        base = userOnly;
    }
    NSString *text = self.query.length ? self.query : self.searchBar.text;
    if (text.length) {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(SKInstalledApp *a, NSDictionary *b) {
            return [a.name localizedCaseInsensitiveContainsString:text] ||
                   [a.bundleID localizedCaseInsensitiveContainsString:text];
        }];
        base = [base filteredArrayUsingPredicate:p];
    }
    self.filtered = base;
    [self.tableView reloadData];
}

- (void)systemSwitchChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:@"ad.showsystemapps"];
    SKLog(@"[apps] show system apps: %d", sw.on ? 1 : 0);
    [self rebuildFiltered];
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.query = text;
    [self rebuildFiltered];
}
@end
