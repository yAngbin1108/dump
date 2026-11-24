//
//  ADXFairPlayJob.h
//  App 扩展层 — FairPlay 用户态砸壳任务
//
//  这是本 AppDump 的核心能力（第三方源码里没有）：不依赖内核漏洞，
//  只靠 mremap_encrypted() 让 fairplayd 把磁盘上的密文页解开再回读，
//  因此「运行漏洞利用」失败也能用。
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ADXLogBlock)(NSString *line);
typedef void (^ADXProgressBlock)(double fraction, NSString *stage, NSString *detail);

@interface ADXFairPlayJob : NSObject

@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *bundlePath;
/// 出包时顺便把 Info.plist 的 MinimumOSVersion 降到 10.0、去掉设备能力限制。
@property (nonatomic, assign) BOOL relaxInstallRestrictions;
@property (nonatomic, copy, nullable) ADXLogBlock log;
@property (nonatomic, copy, nullable) ADXProgressBlock progress;
@property (nonatomic, copy, nullable) void (^completion)(NSString * _Nullable ipaPath,
                                                         NSString * _Nullable error,
                                                         NSString * _Nullable summary);
@property (atomic, assign, readonly) BOOL cancelled;

- (void)start;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END