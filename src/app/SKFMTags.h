//
//  SKFMTags.h
//  Blade — 文件管理器的路径标签（Filza 那种"保存路径"）
//
//  标签存在 NSUserDefaults 里，文件管理器顶部"+"的二级菜单可以：
//    * 把当前路径存成一个具名标签
//    * 点标签直接跳过去
//    * 左滑删除
//

#ifndef SKFMTags_h
#define SKFMTags_h

#import <UIKit/UIKit.h>

@interface SKFMTags : NSObject
/// @[ @{@"name": ..., @"path": ...}, ... ]，顺序即展示顺序。
+ (NSArray<NSDictionary *> *)all;
+ (void)addName:(NSString *)name path:(NSString *)path;
+ (void)removeAtIndex:(NSInteger)index;
+ (BOOL)hasPath:(NSString *)path;
@end

/// 标签管理页。currentPath 是打开这一页时所在的路径，用来做"保存当前路径"。
@interface SKFMTagsViewController : UIViewController
- (instancetype)initWithCurrentPath:(NSString *)path;
@end

#endif /* SKFMTags_h */
