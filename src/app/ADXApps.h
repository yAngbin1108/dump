//
//  ADXApps.h
//  App 扩展层 — 已安装应用扫描（只读，走文件系统，和第三方列表互不影响）
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ADXApp : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, copy) NSString *executable;
@property (nonatomic, assign) BOOL isSystem;
@end

/// 扫 /var/containers/Bundle/Application + 系统应用目录。
/// 需要沙盒逃逸才有内容（返回空数组说明没逃逸或读不到）。
NSArray<ADXApp *> *ADXScanInstalledApps(void);

NS_ASSUME_NONNULL_END