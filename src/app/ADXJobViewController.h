//
//  ADXJobViewController.h
//  App 扩展层 — 砸壳进度页
//
#import <UIKit/UIKit.h>
#import "ADXApps.h"

NS_ASSUME_NONNULL_BEGIN

@interface ADXJobViewController : UIViewController
- (instancetype)initWithApp:(ADXApp *)app relaxInstallRestrictions:(BOOL)relax;
@end

NS_ASSUME_NONNULL_END