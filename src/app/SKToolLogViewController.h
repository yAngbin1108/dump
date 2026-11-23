//
//  SKToolLogViewController.h
//  AppDump — 工具页任务日志（降级 / 阻止更新的执行输出）
//

#ifndef SKTOOLLOGVIEWCONTROLLER_H
#define SKTOOLLOGVIEWCONTROLLER_H

#import <UIKit/UIKit.h>

@interface SKToolLogViewController : UIViewController

- (instancetype)initWithTitle:(NSString *)title;

/// 追加一行（任意线程可调，内部切主线程）。
- (void)appendLine:(NSString *)line;

/// 顶部状态文字（可为 nil 清空）。
- (void)setStatusText:(NSString *)text;

/// 任务结束：显示结果并允许关闭。
- (void)finishWithSuccess:(BOOL)success message:(NSString *)message;

@end

#endif /* SKTOOLLOGVIEWCONTROLLER_H */
