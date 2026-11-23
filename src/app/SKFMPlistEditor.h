//
//  SKFMPlistEditor.h
//  Blade — plist 编辑器
//
//  文件管理器里点 .plist 时用它接手，而不是丢给纯文本编辑器：
//
//    * 保留原格式保存 —— 二进制 plist 存回去还是二进制，不会因为经过一次
//      文本编辑就变成 XML（iOS 很多 plist 是二进制的，用文本编辑器打开是乱码，
//      保存下去还会把文件写坏）
//    * 按类型编辑 —— 字符串/数字给输入框，布尔给开关，日期给日期选择器，
//      data 用 base64，字典/数组点进去继续改
//    * 增删键、删元素、滑动手势删除
//

#ifndef SKFMPlistEditor_h
#define SKFMPlistEditor_h

#import <UIKit/UIKit.h>

@interface SKFMPlistEditorViewController : UIViewController

/// 打开 path 指向的 plist。无法解析时返回 nil。
- (instancetype)initWithPath:(NSString *)path;

/// 这个路径看起来是 plist 吗（按扩展名 + 内容前几个字节）。
+ (BOOL)looksLikePlist:(NSString *)path;

@end

#endif /* SKFMPlistEditor_h */
