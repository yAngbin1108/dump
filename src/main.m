//
//  main.m
//  AppDump — four tabs: Kernel / App Decrypt / Processes / Files.
//
//  Layout follows the original AppDump (SwiftUI List + Section + LabeledContent
//  rows with a leading header label and a trailing status accessory), rebuilt
//  with UIKit.
//

#import <UIKit/UIKit.h>
#import <dlfcn.h>

#import "SKKeepAlive.h"
#import "SKLaraFileBrowser.h"
#import "SKAppBrowser.h"
#import "SKCrashGuard.h"
#import "SKKernelViewController.h"
#import "SKLog.h"
#import "SKStorage.h"
#import "ProcessListViewController.h"
#import "offsets.h"

#pragma mark - 拉起相关的 entitlement 探针

// 前台打开任何 App 都不需要额外权限（LSApplicationWorkspace 谁都能调），但带
// __ActivateSuspended 的"挂起启动"要 FrontBoard 认可我们是可信客户端：签名里
// 那几条 com.apple.private.frontboard.* / springboard.* 必须在**运行时**生效。
// 装包时被重新签名的话，这些不在描述文件里的私有 entitlement 会被剥掉，于是
// 拉起请求被受理却不起进程 —— 表现就是砸壳只能抢前台。这里把实际生效值打出来。
static void sk_log_launch_entitlements(void)
{
    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    if (!sec) { SKLog(@"[ent] Security.framework not loadable"); return; }
    CFTypeRef (*createTask)(CFAllocatorRef) =
        (CFTypeRef (*)(CFAllocatorRef))dlsym(sec, "SecTaskCreateFromSelf");
    CFTypeRef (*copyValue)(CFTypeRef, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(CFTypeRef, CFStringRef, CFErrorRef *))
        dlsym(sec, "SecTaskCopyValueForEntitlement");
    if (!createTask || !copyValue) { SKLog(@"[ent] SecTask API missing"); return; }
    CFTypeRef task = createTask(kCFAllocatorDefault);
    if (!task) { SKLog(@"[ent] SecTaskCreateFromSelf failed"); return; }

    NSArray<NSString *> *keys = @[
        @"platform-application",
        @"com.apple.private.frontboard.open",
        @"com.apple.private.frontboard.launch-applications",
        @"com.apple.private.springboard.open",
        @"com.apple.springboard.launchapplications",
        @"get-task-allow",
    ];
    for (NSString *key in keys) {
        CFTypeRef value = copyValue(task, (__bridge CFStringRef)key, NULL);
        BOOL on = NO;
        if (value) {
            on = !CFEqual(value, kCFBooleanFalse);
            CFRelease(value);
        }
        SKLog(@"[ent] %@ = %s", key, on ? "true" : "false");
    }
    CFRelease(task);
}

@interface SKRootTabBarController : UITabBarController
@end

@implementation SKRootTabBarController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tabBar.itemPositioning = UITabBarItemPositioningCentered;

    // 底栏必须不透明：之前内容会从栏下面透出来。
    UITabBarAppearance *ap = [[UITabBarAppearance alloc] init];
    [ap configureWithOpaqueBackground];
    ap.backgroundColor = UIColor.systemBackgroundColor;
    ap.shadowColor = UIColor.separatorColor;
    self.tabBar.standardAppearance = ap;
    self.tabBar.scrollEdgeAppearance = ap;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rebuildTabs)
                                                 name:@"SKSettingsDidDismissNotification"
                                               object:nil];
    // 冷启动固定落在利用页（第 0 个 tab），不要停在上次停留的 tab 上。
    [self rebuildTabsPreservingSelection:NO];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)rebuildTabs {
    [self rebuildTabsPreservingSelection:YES];
}

// 设置里的「在标签页中显示文件管理器」直接决定 Files 这个 tab 存不存在。
- (void)rebuildTabsPreservingSelection:(BOOL)preserve {
    BOOL showFiles = [NSUserDefaults.standardUserDefaults objectForKey:@"ad.fmtab"]
        ? [NSUserDefaults.standardUserDefaults boolForKey:@"ad.fmtab"] : YES;

    // 只在文件管理器 tab 该不该在这一点真的变了时才重建：重建会把每个 tab 的
    // 导航栈一起丢掉，没必要为了关一次设置页就重置一次。
    // 4 个 tab = 砸壳 / 应用 / 进程 / 文件；关掉文件管理器就是 3 个。
    if (self.viewControllers.count == (showFiles ? 4u : 3u)) return;

    // UITabBarController 在 viewControllers 还没设时 selectedIndex 是 NSNotFound，
    // 直接拿来算会变成 -1，最后落到的 tab 就不确定了 —— 冷启动一律 0。
    NSInteger selected = preserve ? self.selectedIndex : 0;
    if (selected < 0 || selected == (NSInteger)NSNotFound) selected = 0;
    NSMutableArray<UIViewController *> *tabs = [NSMutableArray array];

    SKKernelViewController *kernel = [SKKernelViewController new];
    UINavigationController *navKernel = [[UINavigationController alloc] initWithRootViewController:kernel];
    // 三个 tab 都要有名字：iPadOS 18 的新底栏只给选中的那个显示标签，
    // 标题留空的话没选中的两个就完全没有文字。
    navKernel.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"砸壳"
                                                        image:[UIImage systemImageNamed:@"wrench.and.screwdriver.fill"]
                                                selectedImage:nil];
    [tabs addObject:navKernel];

    SKAppBrowserViewController *dump = [SKAppBrowserViewController new];
    UINavigationController *navDump = [[UINavigationController alloc] initWithRootViewController:dump];
    navDump.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"应用"
                                                      image:[UIImage systemImageNamed:@"lock.open.fill"]
                                              selectedImage:nil];
    [tabs addObject:navDump];

    // 进程管理：列表 / 结束进程 / 内存编辑。数据来自内核 allproc 遍历，
    // 需要先运行利用链；没跑的话列表是空的，页面会自己提示。
    ProcessListViewController *procs = [ProcessListViewController new];
    UINavigationController *navProcs = [[UINavigationController alloc] initWithRootViewController:procs];
    navProcs.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"进程"
                                                       image:[UIImage systemImageNamed:@"list.bullet.rectangle"]
                                               selectedImage:nil];
    [tabs addObject:navProcs];

    if (showFiles) {
        // Files starts at "/" and uses the directory browser rebuilt from the
        // original's DirectoryView.
        SKLaraFileBrowser *files = [[SKLaraFileBrowser alloc] initWithPath:@"/"];
        UINavigationController *navFiles = [[UINavigationController alloc] initWithRootViewController:files];
        navFiles.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"文件"
                                                           image:[UIImage systemImageNamed:@"folder.fill"]
                                                   selectedImage:nil];
        [tabs addObject:navFiles];
    }

    self.viewControllers = tabs;
    self.selectedIndex = MAX(0, MIN(selected, (NSInteger)tabs.count - 1));
}

@end

#pragma mark - AppDelegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate


// —— 场景重建 ——
// 进后台时 iOS 会把我们的场景摘掉；此后所有"激活"请求（openURL / SBS /
// FBSSystemService / Safari 转交）都会被受理但不显示。回来时把窗口重新建起来
// 并 makeKeyAndVisible，激活才有落点。
- (void)sk_rebuildWindow {
    if (!self.window || !self.window.rootViewController) {
        self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        self.window.rootViewController = [SKRootTabBarController new];
    }
    [self.window makeKeyAndVisible];
    SKLog(@"[scene] window rebuilt and made key");
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    SKLog(@"[scene] openURL %@", url.absoluteString);
    [self sk_rebuildWindow];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    SKLog(@"[scene] willEnterForeground");
    [self sk_rebuildWindow];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    SKLog(@"[scene] didBecomeActive");
    [self sk_rebuildWindow];
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    SKLogCaptureStdout();
    SKCrashGuardInstall();
    // 装包被重签时私有 entitlement 会被剥，挂起启动就会被系统丢掉。
    sk_log_launch_entitlements();
    SKStorageSweepOnLaunch();
    SKKeepAliveApplyFromDefaults();   // 设置里开着就继续保活

    // 偏移表是静态的（按 iOS 版本/芯片），不依赖内核，所以启动时就填上：
    // 这样设置里的「修改偏移」显示的是真实值，而不是一屏 0x0。
    offsets_init();

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [SKRootTabBarController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}
