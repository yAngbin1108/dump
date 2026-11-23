//
//  SKOverlay.h
//  Blade — RemoteCall-injected floating overlay inside SpringBoard
//
//  HOW THIS WORKS (and what it cannot do)
//  --------------------------------------
//  RemoteCall is a remote Objective-C message-sending engine: it lets us call
//  any method of any class inside SpringBoard (`objc_getClass` +
//  `sel_registerName` + `objc_msgSend`, driven through Mach exception ports and
//  ARM64 thread-state ROP). It is *not* a JavaScript bridge, and it cannot run
//  arbitrary code of ours in that process — AMFI/TXM on iOS 17.5 rejects the
//  unsigned dylib that would normally carry our logic.
//
//  So the injected UI cannot have our code as a touch handler. Instead we build
//  it out of controls that carry their own interaction state, and poll that
//  state from Blade:
//
//    * A one-item UISegmentedControl is used as a button. We reset its
//      `selectedSegmentIndex` to UISegmentedControlNoSegment after every poll,
//      so the next tap flips it to 0 — that transition *is* the tap event.
//    * A UIScrollView carries its own `contentOffset`, so dragging inside the
//      ball is observable the same way.
//
//  Blade polls on a fast timer and re-renders remotely. That is the only
//  interaction channel available, which is why the refresh rate matters.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SKOverlayEvent) {
    SKOverlayEventNone = 0,
    SKOverlayEventBallTapped,
    SKOverlayEventRowTapped,      // `rowIndex` valid
    SKOverlayEventBallDragged,    // `dragDelta` valid
};

@interface SKOverlay : NSObject

+ (instancetype)shared;

/// Attach to SpringBoard and put the ball on screen. Returns nil on success or
/// a reason on failure.
- (nullable NSString *)start;

/// Remove the injected window and tear the remote session down.
- (void)stop;

@property (nonatomic, readonly) BOOL running;

/// Whether the panel is currently expanded (ball alone when NO).
@property (nonatomic, readonly) BOOL panelOpen;

/// Poll the injected controls once. `handler` reports what changed.
/// Called on the caller's thread; keep it cheap.
- (void)pollWithHandler:(void (^)(SKOverlayEvent event, NSInteger rowIndex, CGFloat value))handler;

/// Render the process list into the injected panel (or hide it with nil).
- (void)showPanelWithTitle:(NSString *)title rows:(NSArray<NSString *> *)rows;
- (void)hidePanel;

/// Move the ball by a delta, in points.
- (void)moveBallBy:(CGPoint)delta;

@end

NS_ASSUME_NONNULL_END
