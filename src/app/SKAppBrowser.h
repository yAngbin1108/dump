//
//  SKAppBrowser.h
//  SandboxKit — installed-app browser
//
//  Shows every installed app with its icon and name. Tapping one offers:
//
//    主程序目录 (.app)   browse the bundle itself
//    Group 目录          the app's shared AppGroup container, if it has one
//    数据目录            the app's data container
//    砸壳                decrypt it into an .ipa
//
//  Pushed inside a UINavigationController so every screen gets a Back button.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SKAppBrowserViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
