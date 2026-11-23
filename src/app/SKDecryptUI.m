//
//  SKDecryptUI.m
//  SandboxKit — 砸壳 (decryption) interface
//
//  Flow (mirrors lara's DecryptView, with the fixes noted):
//
//    1. launch the target so its pages are faulted in and therefore decrypted
//    2. copy the bundle into a scratch dir
//    3. decrypt the main executable into the copy
//    4. decrypt every *encrypted* Mach-O inside the copy — not just
//       Frameworks/*.framework but also PlugIns/*.appex and any nested
//       .framework/.dylib. lara only walked Frameworks/*.framework, so apps
//       shipping an encrypted extension had that extension left encrypted and
//       the installed app misbehaved.
//    5. move into Payload/ and zip to .ipa
//
//  The actual decryption correctness fix (matching the right Mach-O by
//  LC_UUID, and refusing to emit a binary whose pages came back still
//  encrypted) lives in kexploit/decrypt.m.
//

#import "SKDecryptUI.h"
#import "SKAppEvents.h"
#import "SKLoc.h"
#import "SKLog.h"
#import "SKStorage.h"
#import "SKZipWriter.h"
#import "decrypt.h"
#import "cydecrypt.h"
#import "darksword.h"
#import "SKSandboxKeeper.h"

#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const kBundleRoot = @"/var/containers/Bundle/Application";

// 砸壳方式，存在 NSUserDefaults 里，下次进来还是同一个。
static NSString * const kMethodKey = @"sk.decrypt.method";

// 三档：
//   自动   —— 按系统版本判断：能「不启动 App」砸壳就用 Cyanide 的本地层
//            （mremap_encrypted），不能就用 lara（启动 App 读已解密页）；
//            万一本地层被拒，运行中也会自动回落到 lara。
//   不启动 —— 强制 Cyanide 本地层；它不启动 App、不用 RemoteCall、不碰内核原语。
//   lara   —— blade 原来的路径，启动 App 逐页读内存。
typedef NS_ENUM(NSInteger, SKDecryptChoice) {
    SKDecryptChoiceAuto = 0,   // Cyanide 的做法：后台挂起启动 + 分段映射
    SKDecryptChoiceLara,       // blade 原版：前台启动 + 逐页读
};

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Runner (progress + work)
// ─────────────────────────────────────────────────────────────────────────────

@interface SKDecryptRunnerViewController ()
@property (nonatomic, strong) UITextView *log;
@property (nonatomic, strong) UISegmentedControl *methodBar;
@property (nonatomic, copy) NSString *appName, *bundleID, *bundlePath, *executable;
@property (nonatomic, assign) BOOL didLaunchTarget;
/// 自动档里 Cyanide 本地层被拒、已经落到 lara 之后就一直用 lara。
@property (nonatomic, assign) BOOL autoFellBackToLara;
- (void)emit:(NSString *)s;
- (void)run;
- (void)finishWithIPA:(NSString *)path error:(NSString *)err;
@end



@implementation SKDecryptRunnerViewController

- (instancetype)initWithAppName:(NSString *)n bundleID:(NSString *)b
                     bundlePath:(NSString *)p executable:(NSString *)e {
    self = [super init];
    if (self) {
        _appName = [n copy]; _bundleID = [b copy];
        _bundlePath = [p copy]; _executable = [e copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.appName;
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    // 砸壳方式选择条：自动（CY 分段）/ lara（逐页）
    self.methodBar = [[UISegmentedControl alloc] initWithItems:
                      @[ SKLoc(@"decrypt.method.auto"),
                         SKLoc(@"decrypt.method.lara") ]];
    NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:kMethodKey];
    if (saved < (NSInteger)SKDecryptChoiceAuto || saved > (NSInteger)SKDecryptChoiceLara)
        saved = SKDecryptChoiceAuto;
    self.methodBar.selectedSegmentIndex = saved;
    [self.methodBar addTarget:self action:@selector(methodChanged:)
             forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.methodBar];

    self.log = [[UITextView alloc] initWithFrame:CGRectZero];
    self.log.editable = NO;
    self.log.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.log.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.view addSubview:self.log];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Decryption takes a while and we may launch the target app (which
        // backgrounds us). Without a background-task assertion iOS suspends the
        // process mid-decrypt, which looks like a hang or a crash.
        __block UIBackgroundTaskIdentifier bg = UIBackgroundTaskInvalid;
        bg = [[UIApplication sharedApplication]
              beginBackgroundTaskWithName:@"decrypt"
                        expirationHandler:^{
            [[UIApplication sharedApplication] endBackgroundTask:bg];
            bg = UIBackgroundTaskInvalid;
        }];

        // 砸壳这里**不执行任何利用**：利用链只在第一次点「运行利用」时跑，砸壳
        // 既不重放逃逸也不碰它。keeper 只在会用到内核原语的路径（lara）上暂停，
        // 避免两个使用者同时动内核状态；Cyanide 本地层是纯系统调用，可以和它并存。
        BOOL mayUseKernel = YES;    // 两条路径都会用到内核原语
        BOOL keeperWasRunning = [SKSandboxKeeper sharedKeeper].running;
        if (mayUseKernel && keeperWasRunning) [[SKSandboxKeeper sharedKeeper] stop];

        [self run];

        if (mayUseKernel && keeperWasRunning) [[SKSandboxKeeper sharedKeeper] start];

        if (bg != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:bg];
            bg = UIBackgroundTaskInvalid;
        }
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    // 必须让开安全区：这个页面在导航栈里，edgesForExtendedLayout 默认是 all，
    // view 会铺到导航栏底下 —— 用 view.bounds 定位的话选择条会顶到屏幕最上面，
    // 正好被导航栏/状态栏吃掉，点不到。
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat barH = 32;
    CGFloat top = safe.top + 8;
    self.methodBar.frame = CGRectMake(safe.left + 12, top,
                                      b.size.width - safe.left - safe.right - 24, barH);
    CGFloat y = top + barH + 8;
    self.log.frame = CGRectMake(safe.left, y,
                                b.size.width - safe.left - safe.right,
                                b.size.height - y - safe.bottom);
}

// ── 砸壳方式 ──────────────────────────────────────────────────────────────

- (SKDecryptChoice)choice {
    NSInteger i = [[NSUserDefaults standardUserDefaults] integerForKey:kMethodKey];
    if (i < (NSInteger)SKDecryptChoiceAuto || i > (NSInteger)SKDecryptChoiceLara)
        i = SKDecryptChoiceAuto;
    return (SKDecryptChoice)i;
}

- (void)methodChanged:(UISegmentedControl *)seg {
    [[NSUserDefaults standardUserDefaults] setInteger:seg.selectedSegmentIndex forKey:kMethodKey];
    [self emit:[self methodSummary]];
}

/// 这一次砸壳到底走不走 Cyanide 的「不启动 App」层。
- (BOOL)usesChunked {
    return [self choice] != SKDecryptChoiceLara;
}

- (NSString *)methodSummary {
    if ([self choice] == SKDecryptChoiceLara) return SKLoc(@"decrypt.method.lara.desc");
    return SKLoc(@"decrypt.method.auto.desc");
}

/// 找到（必要时启动）目标进程，lara 路径用。
- (pid_t)ensureTargetPid {
    pid_t pid = find_process_pid(self.executable.UTF8String);
    if (pid > 0) return pid;
    [self emit:SKLoc(@"decrypt.launching")];
    self.didLaunchTarget = YES;
    launch_app(self.bundleID.UTF8String);
    for (int i = 0; i < 40 && pid <= 0; i++) {
        usleep(500 * 1000);
        pid = find_process_pid(self.executable.UTF8String);
    }
    return pid;
}

- (void)emit:(NSString *)s {
    // Mirror into Documents/sk.log as well. The on-screen log is the only other
    // destination, and when the run ends with the app being re-activated (or
    // killed) that view is gone — which is exactly the state the user could not
    // report: the packaging result, "no IPA" and the share sheet all happen
    // after the last line that used to reach the file.
    SKLog(@"[decrypt-ui] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.log.text = [self.log.text stringByAppendingFormat:@"%@\n", s];
        [self.log scrollRangeToVisible:NSMakeRange(self.log.text.length, 0)];
    });
}

// The view controller that can actually present something right now. `self` may
// already be detached: finishWithIPA: re-opens the app, iOS rebuilds the window
// hierarchy, and a present on a controller that is no longer in the hierarchy is
// a silent no-op — which is why the share sheet never appeared.
- (UIViewController *)topPresentable {
    UIWindow *key = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) { key = w; break; }
    }
    if (!key) key = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)vc).topViewController;
        if (top) vc = top;
    }
    if (!vc || !vc.view.window) {
        UINavigationController *nav = self.navigationController;
        if (nav && nav.view.window) vc = nav;
    }
    return vc;
}

- (void)finishWithIPA:(NSString *)path error:(NSString *)err {
    [[NSNotificationCenter defaultCenter] postNotificationName:SKDumpDidFinishNotification object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        SKLog(@"[decrypt-ui] finish: path=%@ error=%@", path ?: @"(none)", err ?: @"(none)");

        // Deliberately do NOT re-open ourselves here.
        //
        // launch_app(our own bundle id) goes through LSApplicationWorkspace,
        // which TERMINATES and relaunches the already-installed app rather than
        // just foregrounding it. That killed the view controller we are about to
        // present from (so the share sheet never appeared), and — because every
        // launch re-runs the kernel exploit — it also meant a second full
        // exploit pass for a single 砸壳. The device log shows exactly that: a
        // fresh "=== app launched ===" immediately after each decrypt.
        //
        // Presenting from the top-most controller once the app is active again
        // (below) covers coming back from the target app without restarting.

        if (err) {
            // 原版 AppDump 在这种情况下也是提示用户先手动打开目标 App：
            // "Process not found after launch. Try manually."
            NSString *shown = err;
            if ([err containsString:@"process not found"] ||
                [err containsString:@"app is not running"]) {
                shown = @"目标 App 没在运行：先打开它一次（放到后台也行），回来再砸就完全不跳转。";
            }
            UIViewController *host = [self topPresentable];
            UIAlertController *al = [UIAlertController
                alertControllerWithTitle:SKLoc(@"decrypt.failed.title") message:shown
                          preferredStyle:UIAlertControllerStyleAlert];
            // 只关弹窗，不退出页面：日志留着，返回由用户自己点返回键。
            [al addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.ok")
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];
            [host presentViewController:al animated:YES completion:nil];
            return;
        }

        // Success: hand the IPA straight to the system share sheet so it can go
        // to Files, AirDrop or another app. Do it once the app is actually
        // active again — presenting while the foreground transition is still in
        // flight is another way for the sheet to be dropped.
        void (^showShare)(void) = ^{
            UIViewController *host = [self topPresentable];
            if (!host.view.window) {
                // Nothing can present yet. Say so in the log and in an alert so
                // the run is never silently lost.
                SKLog(@"[decrypt-ui] no window to present the share sheet from; IPA is at %@", path);
                return;
            }
            NSURL *url = [NSURL fileURLWithPath:path];
            UIActivityViewController *av =
                [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                 applicationActivities:nil];
            av.popoverPresentationController.sourceView = host.view;
            av.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(host.view.bounds), CGRectGetMidY(host.view.bounds), 1, 1);
            // 分享完仍然停在这一页，只有左上角返回键会关掉它。
            av.completionWithItemsHandler =
                ^(UIActivityType type, BOOL completed, NSArray *items, NSError *e) {
                SKLog(@"[decrypt-ui] share sheet finished; staying on the decrypt page");
            };
            [host presentViewController:av animated:YES completion:^{
                SKLog(@"[decrypt-ui] share sheet presented for %@", path);
            }];
        };

        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            // Already frontmost: present on the next runloop turn.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), showShare);
        } else {
            __block id token = nil;
            token = [NSNotificationCenter.defaultCenter
                     addObserverForName:UIApplicationDidBecomeActiveNotification
                                 object:nil queue:NSOperationQueue.mainQueue
                             usingBlock:^(NSNotification *n) {
                if (token) { [NSNotificationCenter.defaultCenter removeObserver:token]; token = nil; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), showShare);
            }];
            // Do not wait forever if the activation notification never arrives.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (token) {
                    [NSNotificationCenter.defaultCenter removeObserver:token];
                    token = nil;
                    SKLog(@"[decrypt-ui] app never became active; presenting anyway");
                    showShare();
                }
            });
        }
    });
}

// ── 解密一个 Mach-O：按顶部选的方式分发 ────────────────────────────────────
// 返回 0 表示这个文件已经处理好（包括「本来就没加密」这种）。失败时已经写进
// 日志，调用方只需要计数。
- (int)decryptOne:(NSString *)src to:(NSString *)dst pid:(pid_t)pid {
    // 扩展和 Watch 里的二进制只在它们自己的进程里加载，绝大多数时候根本读不到。
    // 失败就直接交给调用方整包剔除，不要再回落到逐页方案刷一屏失败日志。
    BOOL isExtension = [src containsString:@".appex/"] || [src containsString:@"/Watch/"];
    if ([self usesChunked]) {
        NSString *why = nil;
        if ([[SKCyDecryptor shared] decryptFile:src to:dst why:&why]) return 0;
        [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.cy.fail"),
                    src.lastPathComponent, why.length ? why : @"?"]];
        // 默认就是后台拉起 + 分段映射（CY 的做法）。拉起失败或读不到镜像时
        // 自动落到 lara 原版继续，别让整次砸壳白跑。
        if (isExtension) return -1;
        [self emit:SKLoc(@"decrypt.cy.fallback")];
        self.autoFellBackToLara = YES;
        pid = [self ensureTargetPid];
        if (pid <= 0) {
            [self emit:SKLoc(@"decrypt.no.process")];
            return -1;
        }
    }
    return decrypt_binary_search(src.UTF8String, pid, dst.UTF8String);
}

// ── the actual work ────────────────────────────────────────────────────────
- (void)run {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *outDir = [docs stringByAppendingPathComponent:@"Decrypted"];
    NSString *workDir = [outDir stringByAppendingPathComponent:
                         [@".tmp_" stringByAppendingString:self.bundleID]];
    NSString *payload = [workDir stringByAppendingPathComponent:@"Payload"];
    NSString *appName = self.bundlePath.lastPathComponent;
    NSString *destApp = [workDir stringByAppendingPathComponent:appName];
    NSString *ipaPath = [[outDir stringByAppendingPathComponent:
                          [self.appName stringByReplacingOccurrencesOfString:@" " withString:@""]]
                         stringByAppendingPathExtension:@"ipa"];

    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];
    // 除了自己这个，上一轮失败或被系统回收留下的别的 .tmp_* 也一起清掉
    SKStorageRemoveDecryptWorkDirs();
    [fm removeItemAtPath:workDir error:NULL];
    [fm createDirectoryAtPath:payload withIntermediateDirectories:YES attributes:nil error:NULL];

    [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.target"), self.appName, self.bundleID]];

    // ── 1. 选引擎；lara 要目标 App 跑起来，Cyanide 本地层不用 ──────────────
    pid_t pid = 0;
    [[SKCyDecryptor shared] reset];
    [[SKCyDecryptor shared] setBundlePath:self.bundlePath bundleID:self.bundleID
                               executable:self.executable];
    [self emit:[self methodSummary]];
    if ([self usesChunked]) {
        // 不启动、不抢前台、不用 RemoteCall —— FairPlay pager 直接解我们自己
        // mmap 进来的那一段。
    } else {
        pid = [self ensureTargetPid];
        if (pid <= 0) {
            [self emit:SKLoc(@"decrypt.no.process")];
            [fm removeItemAtPath:workDir error:NULL];
            [self finishWithIPA:nil error:SKLoc(@"decrypt.err.noProcess")];
            return;
        }
        [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.pid"), pid]];
    }

    set_log_callback(NULL);
    set_progress_callback(NULL);

    // ── 2. copy the bundle ────────────────────────────────────────────────
    [self emit:SKLoc(@"decrypt.copying")];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:self.bundlePath];
    for (NSString *rel in en) {
        NSString *src = [self.bundlePath stringByAppendingPathComponent:rel];
        NSString *dst = [destApp stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir]) continue;
        if (isDir) [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:NULL];
        else       [fm copyItemAtPath:src toPath:dst error:NULL];
    }

    // ── 3. decrypt the main executable ────────────────────────────────────
    NSString *srcMain = [self.bundlePath stringByAppendingPathComponent:self.executable];
    NSString *dstMain = [destApp stringByAppendingPathComponent:self.executable];
    [self emit:SKLoc(@"decrypt.main")];
    // The main binary is the one case where the system-wide sweep is worth its
    // cost: if procbyname() picked a same-named process, this is what finds the
    // app that actually has the image.
    decrypt_set_global_scan(true);
    if ([self decryptOne:srcMain to:dstMain pid:pid] != 0) {
        [self emit:SKLoc(@"decrypt.main.fail")];
        [fm removeItemAtPath:workDir error:NULL];
        [self finishWithIPA:nil error:SKLoc(@"decrypt.err.main")];
        return;
    }
    [self emit:SKLoc(@"decrypt.main.ok")];

    // ── 4. decrypt every other encrypted Mach-O in the copy ───────────────
    // Covers Frameworks/*.framework, PlugIns/*.appex, and any stray .dylib.
    int decrypted = 0, failed = 0;
    NSArray *all = [fm subpathsAtPath:destApp] ?: @[];

    // The preferred pid resolves frameworks (loaded by the host app), and
    // decrypt_binary_search() already tries every process with a matching name,
    // which is how a running extension is found. The system-wide UUID sweep is
    // for the main binary only: running it for every encrypted file in the
    // bundle meant tens of seconds of continuous kernel I/O each time, and on
    // iPadOS 18.4.1 that ended in a watchdog reset.
    decrypt_set_global_scan(false);

    // A .appex / Watch bundle that could not be decrypted is removed whole:
    // shipping it encrypted makes the installed app fail to launch, which is
    // worse than shipping without that extension.
    NSMutableSet<NSString *> *droppedBundles = [NSMutableSet set];

    for (NSString *rel in all) {
        @autoreleasepool {
            BOOL inDropped = NO;
            for (NSString *b in droppedBundles)
                if ([rel hasPrefix:[b stringByAppendingString:@"/"]]) { inDropped = YES; break; }
            if (inDropped) continue;
            NSString *full = [destApp stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;

            // Only Mach-O files: match the name used by frameworks / appex /
            // dylibs. Everything else is skipped cheaply.
            NSString *ext = rel.pathExtension.lowercaseString;
            BOOL candidate = [ext isEqualToString:@"dylib"]
                          || [full.pathExtension isEqualToString:@""]  // framework/appex binary
                          || [rel containsString:@".framework/"]
                          || [rel containsString:@".appex/"];
            if (!candidate) continue;
            if ([full isEqualToString:dstMain]) continue;

            if (is_encrypted_path(full.UTF8String) <= 0) continue;

            [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.other"), rel]];
            // Extensions live in their own process, so the host pid will not
            // match their LC_UUID. The lara path falls back to scanning every
            // process for the image; the Cyanide path maps the image's pager
            // object instead and needs no process at all.
            if ([self decryptOne:full to:full pid:pid] != 0) {
                // 扩展只在它自己的进程里运行时才加载；解不开就把这个包整包剔除。
                NSRange appex = [rel rangeOfString:@".appex/"];
                NSString *bundle = nil;
                if ([rel hasPrefix:@"Watch/"]) bundle = @"Watch";
                else if (appex.location != NSNotFound)
                    bundle = [rel substringToIndex:appex.location + 6];   // ".../Name.appex"
                if (bundle) {
                    [droppedBundles addObject:bundle];
                    [self emit:[NSString stringWithFormat:@"excluded %@ (not decryptable)", bundle]];
                } else {
                    [self emit:[NSString stringWithFormat:@"failed %@", rel]];
                }
                failed++;
            } else {
                decrypted++;
            }
        }
    }
    [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.summary"), decrypted, failed]];

    for (NSString *b in droppedBundles) {
        [fm removeItemAtPath:[destApp stringByAppendingPathComponent:b] error:NULL];
    }
    if (droppedBundles.count)
        [self emit:[NSString stringWithFormat:@"%lu bundle(s) left out of the IPA",
                    (unsigned long)droppedBundles.count]];

    // ── 5. package ────────────────────────────────────────────────────────
    [self emit:SKLoc(@"decrypt.packaging")];
    NSString *payloadApp = [payload stringByAppendingPathComponent:appName];
    NSError *mvErr = nil;
    if (![fm moveItemAtPath:destApp toPath:payloadApp error:&mvErr]) {
        [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.err.move"), mvErr.localizedDescription]];
        [fm removeItemAtPath:workDir error:NULL];
        [self finishWithIPA:nil error:mvErr.localizedDescription];
        return;
    }

    // SKZipWriter streams each file straight to disk. The file manager's
    // zipPathTo() buffered the whole bundle in memory, which for a real app
    // meant being jetsam-killed mid-packaging and leaving a zero-byte .ipa.
    __weak typeof(self) weakSelf = self;
    NSString *zipErr = [SKZipWriter zipDirectory:payload
                                          toPath:ipaPath
                                        progress:^(NSString *entry, NSUInteger done, NSUInteger total) {
        // Log sparsely: one line per ~64 entries keeps the console readable.
        if (done % 64 == 0 || done == total) {
            [weakSelf emit:[NSString stringWithFormat:SKLoc(@"decrypt.packing"), (unsigned long)done, (unsigned long)total]];
        }
    }];
    if (zipErr) {
        [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.pack.fail"), zipErr]];
        [fm removeItemAtPath:workDir error:NULL];
        [self finishWithIPA:nil error:zipErr];
        return;
    }

    // Report the real size so a zero-byte result is obvious in the log.
    NSDictionary *outAttrs = [fm attributesOfItemAtPath:ipaPath error:NULL];
    unsigned long long ipaBytes = [outAttrs[NSFileSize] unsignedLongLongValue];
    if (ipaBytes == 0) {
        [self emit:SKLoc(@"decrypt.err.empty")];
        [fm removeItemAtPath:workDir error:NULL];
        [self finishWithIPA:nil error:SKLoc(@"decrypt.err.empty")];
        return;
    }

    [fm removeItemAtPath:workDir error:NULL];
    [self emit:SKLoc(@"decrypt.stay")];
    [self emit:[NSString stringWithFormat:SKLoc(@"decrypt.ok"),
                ipaPath, ipaBytes / 1048576.0]];
    // 收尾：和 CY 一致，不关目标进程。挂起启动之后立刻把它杀掉，会在 SpringBoard
    // 里留下一条没走完的启动记录，攒几条之后系统就不给挂起启动了（只能抢前台）。

    [self finishWithIPA:ipaPath error:nil];
}

@end
