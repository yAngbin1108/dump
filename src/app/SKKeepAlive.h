//
//  SKKeepAlive.h
//  AppDump — 设置 → 保持后台运行
//
//  照 lara 的 keepalive.swift：把一段 1 秒的全静音 wav 用 AVAudioPlayer 无限循环
//  播放，音频会话设成 playback + mixWithOthers。iOS 会因为「正在播放音频」而不
//  挂起进程，这就是保活，不写任何私有 API。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL SKKeepAliveIsOn(void);

/// 打开/关闭保活；返回操作后是否处于开启状态。
BOOL SKKeepAliveSetOn(BOOL on);

/// 启动时调用：按 NSUserDefaults 里的设置决定要不要开（默认关）。
void SKKeepAliveApplyFromDefaults(void);

NS_ASSUME_NONNULL_END
