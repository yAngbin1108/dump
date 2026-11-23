//
//  SKDecryptUI.h
//  SandboxKit — 砸壳 runner
//
//  The app list now lives in SKAppBrowser. This file provides the runner that
//  performs the actual decryption and packaging for one app.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SKDecryptRunnerViewController : UIViewController
- (instancetype)initWithAppName:(NSString *)name
                       bundleID:(NSString *)bundleID
                     bundlePath:(NSString *)bundlePath
                     executable:(NSString *)executable;
@end

NS_ASSUME_NONNULL_END
