//
//  SKPermsEditor.h
//  Blade — 可视化权限编辑器（Filza 风格）
//
//  原来 chmod 只给一个输入框让你敲 0755 —— 敲错了不知道为什么错，也看不出
//  当前每一类的读写执行状态。这里改成 3×3 开关 + 特殊位开关，八进制值实时
//  显示在标题上，改哪一位一眼能看出来。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SKPermsEditor : UIViewController

/// path 是要改的文件，mode 是当前权限（已 & 07777）。
- (instancetype)initWithPath:(NSString *)path mode:(unsigned int)mode;

/// 目标是不是目录。
///
/// 需要它是因为历史 bug：fixC 曾经把只含权限位的值（07777）写进 fsnode.mode，
/// 而那个字段是完整 16 位 —— S_IFDIR/S_IFREG 被清零，目标在磁盘上不再是目录。
/// 拿到 isDir 才能在修复时把类型位补回去。
- (instancetype)initWithPath:(NSString *)path mode:(unsigned int)mode isDir:(BOOL)isDir;

/// 应用成功后回调新的 mode（仅 chmod 成功时调用）。
@property (nonatomic, copy, nullable) void (^onApplied)(unsigned int newMode);

@end

NS_ASSUME_NONNULL_END
