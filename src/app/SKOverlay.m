//
//  SKOverlay.m
//  Blade — RemoteCall-injected floating overlay inside SpringBoard
//

#import "SKLoc.h"
#import "SKOverlay.h"
#import "SKLog.h"
#import "RemoteCall.h"
#import "darksword.h"

#include <objc/runtime.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/sysctl.h>
#include <sys/types.h>

#import "pac.h"
#import "offsets.h"

// Milliseconds since an arbitrary epoch, for the timing traces below.
static double sk_now_ms(void) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1e6;
}

// Declared in kexploit/TaskRop/privateapi.h; redeclared here so this file does
// not have to pull in that whole header.
extern id objc_alloc(Class cls);

// ─────────────────────────────────────────────────────────────────────────────
// Remote helpers layered on RemoteCall's exported primitives.
// ─────────────────────────────────────────────────────────────────────────────

// Borrow -[CAMetalDrawable dirtyRect] as a gadget that loads four doubles from
// [x0+0x20..0x3f] into d0-d3, so methods taking floating-point arguments can be
// called remotely. remote_setCGRect() does the same for whole CGRects; this is
// the single-double case (setWindowLevel:, setAlpha:, setCornerRadius:, ...).
static void skCallWithDouble(RemoteCall *proc, uint64_t obj, uint64_t sel, double v) {
    if (!proc || !obj || !sel) return;
    uint64_t where = proc.trojanMem;
    double block[4] = { v, 0, 0, 0 };
    if (![proc remote_write:where from:block size:sizeof(block)]) return;

    Class cls = NSClassFromString(@"CAMetalDrawable");
    Method m = cls ? class_getInstanceMethod(cls, @selector(dirtyRect)) : NULL;
    void *gadget = m ? method_getImplementation(m) : NULL;
    if (!gadget) return;

    RemoteArbCall(proc, gadget, where - 0x20);
    remote_msg(proc, obj, sel, 0, 0, 0, 0);
}

// ─────────────────────────────────────────────────────────────────────────────
@interface SKOverlay ()
@property (nonatomic, strong) RemoteCall *sb;
@property (nonatomic, assign) BOOL running;

// Remote object handles (addresses inside SpringBoard).
@property (nonatomic, assign) uint64_t window;
@property (nonatomic, assign) uint64_t ball;
@property (nonatomic, assign) uint64_t ballScroll;
@property (nonatomic, assign) uint64_t panel;
@property (nonatomic, assign) uint64_t panelScroll;
@property (nonatomic, assign) uint64_t panelStack;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *rowHandles;

@property (nonatomic, assign) CGPoint ballOrigin;
@property (nonatomic, readwrite) BOOL panelOpen;

// Cached remote selectors (resolving one costs a round trip, and the poll
// timer runs at 20 Hz).
@property (nonatomic, assign) uint64_t selSegGet;
@property (nonatomic, assign) uint64_t selSegSet;
@property (nonatomic, assign) NSUInteger pollCount;
@end

@implementation SKOverlay

+ (instancetype)shared {
    static SKOverlay *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SKOverlay alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) _rowHandles = [NSMutableArray array];
    return self;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Launch-context diagnostics
// ─────────────────────────────────────────────────────────────────────────────

// Everything needed to explain *why* RemoteCall refused to initialise, so the
// answer is on screen instead of requiring another build/test round.
static NSString *skPACDiagnostics(void) {
    cpu_subtype_t cs = 0;
    size_t sz = sizeof(cs);
    int csErr = sysctlbyname("hw.cpusubtype", &cs, &sz, NULL, 0);

    char machine[64] = {0};
    size_t msz = sizeof(machine);
    sysctlbyname("hw.machine", machine, &msz, NULL, 0);

    // Same probe RemoteCall's pacsignworks() performs.
    uint64_t in = 0x1234, out = in;
    __asm__ volatile(
        "mov x16, %[p]\n"
        "mov x17, #0\n"
        ".long 0xDAC10230\n"      // pacia x16, x17
        "mov %[o], x16\n"
        : [o] "=r"(out) : [p] "r"(in) : "x16", "x17");

    // Same probe with a real string discriminator.
    uint64_t in2 = 0x1234, out2 = in2;
    __asm__ volatile(
        "mov x16, %[p]\n"
        "mov x17, %[m]\n"
        ".long 0xDAC10230\n"
        "mov %[o], x16\n"
        : [o] "=r"(out2) : [p] "r"(in2), [m] "r"((uint64_t)0x7481) : "x16", "x17");

    // What the kernel sees for THIS process. If an installer rewrote the
    // main image's cpusubtype the process is not JOP-enabled however we built
    // it, and local pacia becomes a NOP.
    uint32_t imgCpuType = 0, imgCpuSubtype = 0;
    const struct mach_header_64 *mh =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (mh) { imgCpuType = mh->cputype; imgCpuSubtype = mh->cpusubtype; }

    // 这几段原来是相邻字符串字面量拼接成一条格式串；本地化后必须先把它们
    // 拼起来，否则 SKLoc(...) SKLoc(...) 连写是语法错误。
    NSString *diagFmt = [NSString stringWithFormat:@"%@%@%@%@",
                         SKLoc(@"ov.diag.header"), SKLoc(@"ov.diag.main"),
                         SKLoc(@"ov.diag.pacia0"), SKLoc(@"ov.diag.pacia1")];
    return [NSString stringWithFormat:diagFmt,
            machine,
            (int)cs, csErr,
            imgCpuType, imgCpuSubtype,
            is_pac_supported() ? 1 : 0,
            (unsigned long long)in, (unsigned long long)out,
            (out != in) ? SKLoc(@"ov.signed") : SKLoc(@"ov.unchanged"),
            (unsigned long long)in2, (unsigned long long)out2,
            (out2 != in2) ? SKLoc(@"ov.signed") : SKLoc(@"ov.unchanged"),
            pacsignworks() ? 1 : 0];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (NSString *)start {
    if (self.running) return nil;
    if (!ds_is_ready()) return SKLoc(@"ov.err.noKRW");
    if (self.sb) { [self stop]; }

    double t0 = sk_now_ms();
    SKLog(@"overlay.start: connecting to SpringBoard");

    // Attach to SpringBoard.
    RemoteCall *sb = [[RemoteCall alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
    if (!sb) {
        NSString *why = [RemoteCall lastInitError];
        NSString *diag = skPACDiagnostics();
        SKLog(@"overlay.start: FAILED init in %.0fms: %@", sk_now_ms() - t0, why ?: @"(no reason)");
        SKLog(@"overlay.start: diag%@", diag);
        return [NSString stringWithFormat:SKLoc(@"ov.err.springboard"),
                why.length ? [@"：" stringByAppendingString:why] : @"", diag];
    }
    self.sb = sb;
    SKLog(@"overlay.start: RemoteCall ready in %.0fms pid=%d trojanMem=0x%llx",
          sk_now_ms() - t0, sb.pid, sb.trojanMem);

    uint64_t clsUIWindow   = remote_getClass(sb, "UIWindow");
    uint64_t clsUIView     = remote_getClass(sb, "UIView");
    uint64_t clsUIScroll   = remote_getClass(sb, "UIScrollView");
    uint64_t clsUISeg      = remote_getClass(sb, "UISegmentedControl");
    uint64_t clsUIColor    = remote_getClass(sb, "UIColor");
    SKLog(@"overlay.start: classes UIWindow=0x%llx UIView=0x%llx UIScrollView=0x%llx "
          @"UISegmentedControl=0x%llx UIColor=0x%llx",
          clsUIWindow, clsUIView, clsUIScroll, clsUISeg, clsUIColor);
    if (!clsUIWindow || !clsUIView || !clsUISeg || !clsUIColor) {
        [self stop];
        return SKLoc(@"ov.err.noUIKitClass");
    }

    uint64_t selAlloc        = remote_sel(sb, "alloc");
    uint64_t selInitFrame    = remote_sel(sb, "initWithFrame:");
    uint64_t selSetFrame     = remote_sel(sb, "setFrame:");
    uint64_t selSetHidden    = remote_sel(sb, "setHidden:");
    uint64_t selSetBg        = remote_sel(sb, "setBackgroundColor:");
    uint64_t selAddSubview   = remote_sel(sb, "addSubview:");
    uint64_t selSetLevel     = remote_sel(sb, "setWindowLevel:");
    uint64_t selSetRR        = remote_sel(sb, "setCornerRadius:");
    uint64_t selSetClip      = remote_sel(sb, "setClipsToBounds:");
    uint64_t selLayer        = remote_sel(sb, "layer");
    uint64_t selSetAlpha     = remote_sel(sb, "setAlpha:");
    uint64_t selSetUserInt   = remote_sel(sb, "setUserInteractionEnabled:");
    uint64_t selMakeKey      = remote_sel(sb, "makeKeyAndVisible");

    if (!selAlloc || !selInitFrame || !selSetFrame || !selAddSubview) {
        [self stop];
        return SKLoc(@"ov.err.noMethod");
    }

    self.selSegGet = remote_sel(sb, "selectedSegmentIndex");
    self.selSegSet = remote_sel(sb, "setSelectedSegmentIndex:");
    SKLog(@"overlay.start: sel selectedSegmentIndex=0x%llx setSelectedSegmentIndex:=0x%llx",
          self.selSegGet, self.selSegSet);

    // Screen size from our own process — same device, same screen.
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat ballSide = 52;
    self.ballOrigin = CGPointMake(screen.size.width - ballSide - 12,
                                  screen.size.height * 0.35);

    // ── window ────────────────────────────────────────────────────────────
    uint64_t win = RemoteArbCall(sb, objc_alloc, clsUIWindow);
    if (!win) { [self stop]; return SKLoc(@"ov.err.windowAlloc"); }
    CGRect winRect = CGRectMake(self.ballOrigin.x, self.ballOrigin.y, ballSide, ballSide);
    remote_setCGRect(sb, win, selInitFrame, winRect);
    // Float above everything.
    skCallWithDouble(sb, win, selSetLevel, 10000000.0);
    remote_msg(sb, win, selSetBg, remote_msg(sb, clsUIColor, remote_sel(sb, "clearColor"), 0,0,0,0), 0,0,0);
    remote_msg(sb, win, selMakeKey, 0,0,0,0);
    self.window = win;

    // ── ball: a one-item segmented control ────────────────────────────────
    // It carries its own selection state, which is the only interaction
    // channel available to us (see the header).
    uint64_t ball = [self createSegmentedRowWithTitle:@"●" inParent:0 width:ballSide height:ballSide];
    if (!ball) { [self stop]; return SKLoc(@"ov.err.ballCreate"); }
    remote_setCGRect(sb, ball, selSetFrame, CGRectMake(0, 0, ballSide, ballSide));

    uint64_t blue = remote_msg(sb, clsUIColor, remote_sel(sb, "systemBlueColor"), 0,0,0,0);
    remote_msg(sb, ball, remote_sel(sb, "setTintColor:"), blue, 0,0,0);

    remote_msg(sb, win, selAddSubview, ball, 0, 0, 0);
    self.ball = ball;

    // Give the window rounded corners so the control reads as a ball.
    uint64_t layer = remote_msg(sb, win, selLayer, 0,0,0,0);
    skCallWithDouble(sb, layer, selSetRR, ballSide / 2.0);
    remote_msg(sb, win, selSetClip, 1, 0, 0, 0);

    SKLog(@"overlay.start: DONE in %.0fms window=0x%llx ball=0x%llx",
          sk_now_ms() - t0, win, ball);
    self.running = YES;
    return nil;
}

- (void)stop {
    if (self.window && self.sb) {
        // Hide first so a half-torn-down window never lingers on screen.
        remote_msg(self.sb, self.window, remote_sel(self.sb, "setHidden:"), 1, 0, 0, 0);
        remote_msg(self.sb, self.window, remote_sel(self.sb, "resignKeyWindow"), 0,0,0,0);
        self.window = 0;
    }
    if (self.sb) [self.sb destroyRemoteCall];
    self.sb = nil;
    self.ball = 0;
    self.panel = 0;
    self.panelStack = 0;
    self.panelScroll = 0;
    [self.rowHandles removeAllObjects];
    self.panelOpen = NO;
    self.selSegGet = 0;
    self.selSegSet = 0;
    self.pollCount = 0;
    self.running = NO;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Remote view factory
// ─────────────────────────────────────────────────────────────────────────────

// Build a one-item UISegmentedControl inside SpringBoard that we can use as a
// tappable row. The trick is that a freshly built UISegmentedControl reports
// selectedSegmentIndex == 0, i.e. "the user already tapped me". We reset it to
// UISegmentedControlNoSegment (-1) so that only a real touch can move it back
// to >= 0; that -1 -> 0 transition is the tap event `pollWithHandler:` reads.
// Without this reset every row fires a phantom tap on the first poll.
- (uint64_t)createSegmentedRowWithTitle:(NSString *)title
                              inParent:(uint64_t)parent
                                 width:(CGFloat)width
                                height:(CGFloat)height {
    RemoteCall *sb = self.sb;
    if (!sb) return 0;

    uint64_t clsUISeg = remote_getClass(sb, "UISegmentedControl");
    uint64_t clsNSArray = remote_getClass(sb, "NSArray");
    if (!clsUISeg || !clsNSArray) return 0;

    uint64_t nsstr = remote_NSString(sb, title.UTF8String);
    if (!nsstr) return 0;
    uint64_t nsarr = RemoteArbCall(sb, objc_alloc, clsNSArray);
    if (!nsarr) return 0;
    nsarr = remote_msg(sb, nsarr, remote_sel(sb, "initWithObjects:"), nsstr, 0, 0, 0);
    if (!nsarr) return 0;

    uint64_t ctl = RemoteArbCall(sb, objc_alloc, clsUISeg);
    if (!ctl) return 0;
    uint64_t built = remote_msg(sb, ctl, remote_sel(sb, "initWithItems:"), nsarr, 0, 0, 0);
    if (built) ctl = built;

    remote_setCGRect(sb, ctl, remote_sel(sb, "setFrame:"),
                     CGRectMake(0, 0, width, height));

    // The important bit — see the comment above.
    remote_msg(sb, ctl, remote_sel(sb, "setSelectedSegmentIndex:"), (uint64_t)-1, 0, 0, 0);

    if (parent) {
        remote_msg(sb, parent, remote_sel(sb, "addSubview:"), ctl, 0, 0, 0);
    }
    return ctl;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Polling
// ─────────────────────────────────────────────────────────────────────────────

- (void)pollWithHandler:(void (^)(SKOverlayEvent, NSInteger, CGFloat))handler {
    if (!self.running || !self.sb || !handler) return;

    double t0 = sk_now_ms();

    // Resolved once in -start: resolving a selector is itself a remote round
    // trip, and this runs on a timer.
    uint64_t selGetSeg = self.selSegGet;
    uint64_t selSetSeg = self.selSegSet;
    if (!selGetSeg || !selSetSeg) return;

    // Ball: any tap flips it from "no segment" (-1) to 0. Read, then reset so
    // the next tap is another transition.
    if (self.ball) {
        NSInteger sel = (NSInteger)remote_msg(self.sb, self.ball, selGetSeg, 0,0,0,0);
        if (sel >= 0) {
            remote_msg(self.sb, self.ball, selSetSeg, (uint64_t)-1, 0, 0, 0);
            SKLog(@"overlay.poll: ball tapped");
            handler(SKOverlayEventBallTapped, -1, 0);
        }
    }

    // Rows: same trick, one control per row.
    for (NSUInteger i = 0; i < self.rowHandles.count; i++) {
        uint64_t row = self.rowHandles[i].unsignedLongLongValue;
        if (!row) continue;
        NSInteger sel = (NSInteger)remote_msg(self.sb, row, selGetSeg, 0,0,0,0);
        if (sel >= 0) {
            remote_msg(self.sb, row, selSetSeg, (uint64_t)-1, 0, 0, 0);
            SKLog(@"overlay.poll: row %lu tapped", (unsigned long)i);
            handler(SKOverlayEventRowTapped, (NSInteger)i, 0);
        }
    }

    // Only noisy polls are logged, otherwise a 20 Hz timer would flood the file.
    double dt = sk_now_ms() - t0;
    self.pollCount++;
    if (self.pollCount == 1 || dt > 50.0) {
        SKLog(@"overlay.poll: #%lu rows=%lu took %.0fms",
              (unsigned long)self.pollCount,
              (unsigned long)self.rowHandles.count, dt);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Panel
// ─────────────────────────────────────────────────────────────────────────────

- (void)showPanelWithTitle:(NSString *)title rows:(NSArray<NSString *> *)rows {
    if (!self.running || !self.sb) return;
    double tBuild = sk_now_ms();
    RemoteCall *sb = self.sb;

    uint64_t clsUIView   = remote_getClass(sb, "UIView");
    uint64_t clsUIScroll = remote_getClass(sb, "UIScrollView");
    uint64_t clsUISeg    = remote_getClass(sb, "UISegmentedControl");
    uint64_t clsUIColor  = remote_getClass(sb, "UIColor");
    uint64_t selAlloc    = remote_sel(sb, "alloc");

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat panelW = MIN(screen.size.width - 24, 380);
    CGFloat panelH = MIN(screen.size.height * 0.62, 560);
    CGRect panelRect = CGRectMake(12, screen.size.height * 0.16, panelW, panelH);

    // Grow the window to host the panel; it starts out ball-sized.
    CGRect winRect = CGRectMake(0, 0, screen.size.width, screen.size.height);
    remote_setCGRect(sb, self.window, remote_sel(sb, "setFrame:"), winRect);

    if (!self.panel) {
        uint64_t panel = RemoteArbCall(sb, objc_alloc, clsUIView);
        remote_setCGRect(sb, panel, remote_sel(sb, "initWithFrame:"), panelRect);
        remote_msg(sb, panel, remote_sel(sb, "setBackgroundColor:"),
                   remote_msg(sb, clsUIColor, remote_sel(sb, "secondarySystemBackgroundColor"), 0,0,0,0),
                   0, 0, 0);
        uint64_t layer = remote_msg(sb, panel, remote_sel(sb, "layer"), 0,0,0,0);
        skCallWithDouble(sb, layer, remote_sel(sb, "setCornerRadius:"), 14.0);
        remote_msg(sb, panel, remote_sel(sb, "setClipsToBounds:"), 1, 0, 0, 0);
        remote_msg(sb, self.window, remote_sel(sb, "addSubview:"), panel, 0, 0, 0);
        self.panel = panel;

        uint64_t scroll = RemoteArbCall(sb, objc_alloc, clsUIScroll);
        remote_setCGRect(sb, scroll, remote_sel(sb, "initWithFrame:"),
                         CGRectMake(6, 6, panelW - 12, panelH - 12));
        remote_msg(sb, panel, remote_sel(sb, "addSubview:"), scroll, 0, 0, 0);
        self.panelScroll = scroll;
    } else {
        remote_setCGRect(sb, self.panel, remote_sel(sb, "setFrame:"), panelRect);
    }
    remote_msg(sb, self.panel, remote_sel(sb, "setHidden:"), 0, 0, 0, 0);

    // Rebuild the rows. Each row is a one-item segmented control: it needs no
    // target/action, it just reports "I was tapped" through its selection.
    for (NSNumber *h in self.rowHandles) {
        uint64_t r = h.unsignedLongLongValue;
        if (r) remote_msg(sb, r, remote_sel(sb, "removeFromSuperview"), 0,0,0,0);
    }
    [self.rowHandles removeAllObjects];

    CGFloat rowH = 34, y = 4;
    for (NSString *text in rows) {
        uint64_t row = [self createSegmentedRowWithTitle:text inParent:0
                                                   width:panelW - 20 height:rowH];
        if (!row) continue;
        remote_setCGRect(sb, row, remote_sel(sb, "setFrame:"),
                         CGRectMake(4, y, panelW - 20, rowH));
        remote_msg(sb, self.panelScroll, remote_sel(sb, "addSubview:"), row, 0, 0, 0);
        [self.rowHandles addObject:@(row)];
        y += rowH + 4;
    }

    // Content size so the scroll view can actually scroll a long list.
    // CGSize is two doubles, so it goes through the same FP-register gadget.
    uint64_t szSel = remote_sel(sb, "setContentSize:");
    uint64_t where = sb.trojanMem;
    CGSize sz = CGSizeMake(panelW - 12, y + 8);
    [sb remote_write:where from:&sz size:sizeof(sz)];
    Class cls = NSClassFromString(@"CAMetalDrawable");
    Method m = cls ? class_getInstanceMethod(cls, @selector(dirtyRect)) : NULL;
    void *gadget = m ? method_getImplementation(m) : NULL;
    if (gadget) {
        RemoteArbCall(sb, gadget, where - 0x20);
        remote_msg(sb, self.panelScroll, szSel, 0, 0, 0, 0);
    }

    SKLog(@"overlay.showPanel: '%@' %lu rows built in %.0fms",
          title, (unsigned long)self.rowHandles.count, sk_now_ms() - tBuild);
    self.panelOpen = YES;
}

- (void)hidePanel {
    if (!self.running || !self.panel) return;
    remote_msg(self.sb, self.panel, remote_sel(self.sb, "setHidden:"), 1, 0, 0, 0);
    // Shrink the window back to just the ball so it stops swallowing touches.
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat ballSide = 52;
    remote_setCGRect(self.sb, self.window, remote_sel(self.sb, "setFrame:"),
                     CGRectMake(self.ballOrigin.x, self.ballOrigin.y, ballSide, ballSide));
    remote_setCGRect(self.sb, self.ball, remote_sel(self.sb, "setFrame:"),
                     CGRectMake(0, 0, ballSide, ballSide));
    self.panelOpen = NO;
}

- (void)moveBallBy:(CGPoint)delta {
    if (!self.running || !self.window) return;
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat ballSide = 52;
    CGPoint p = CGPointMake(self.ballOrigin.x + delta.x, self.ballOrigin.y + delta.y);
    p.x = MAX(0, MIN(screen.size.width - ballSide, p.x));
    p.y = MAX(0, MIN(screen.size.height - ballSide, p.y));
    self.ballOrigin = p;
    if (self.panelOpen) return;   // panel owns the window while open
    remote_setCGRect(self.sb, self.window, remote_sel(self.sb, "setFrame:"),
                     CGRectMake(p.x, p.y, ballSide, ballSide));
}

@end
