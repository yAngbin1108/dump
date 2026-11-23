//
//  SKToolApps.h
//  AppDump — 「工具」页共用的已安装应用模型与扫描
//
//  「应用降级」按 bundleId 去 iTunes 查历史版本，「阻止更新」按 bundlePath
//  在 .app 父目录建 placeholder，两者都要这同一份列表，所以扫描只写一份。
//

#ifndef SKTOOLAPPS_H
#define SKTOOLAPPS_H

#import <UIKit/UIKit.h>

@interface SKToolApp : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, assign) BOOL isSystem;
@property (nonatomic, strong, nullable) UIImage *icon;
/// .app 父目录（/var/containers/Bundle/Application/<UUID>）
@property (nonatomic, copy, readonly) NSString *groupPath;
/// 该应用的 placeholder 路径（阻止更新的标记目录）
@property (nonatomic, copy, readonly) NSString *placeholderPath;
/// placeholder 目录当前是否存在
@property (nonatomic, assign, readonly) BOOL blocked;
@end

/// 扫描已安装应用。includeSystem=NO 只取用户安装的 App。
NSArray<SKToolApp *> *SKToolLoadApps(BOOL includeSystem);

/// 单个应用的 icon（40pt，已圆角）。
UIImage *SKToolLoadIcon(NSString *bundlePath, NSDictionary *info, CGFloat side);

#endif /* SKTOOLAPPS_H */
