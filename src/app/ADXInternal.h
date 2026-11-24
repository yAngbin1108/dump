//
//  ADXInternal.h
//  App 扩展层（本次合并新增，不改动第三方原有代码）
//
//  统一的日志与公用小函数。所有 extras/ 下的文件都是新增的。
//
#import <Foundation/Foundation.h>
#include <stdio.h>
#import <UIKit/UIKit.h>

/// 统一日志：走 stdout（第三方 App 的日志页抓的就是 stdout）同时 NSLog。
#define ADXLogf(fmt, ...)                                                        \
    do {                                                                         \
        NSString *adx_s__ = [NSString stringWithFormat:fmt, ##__VA_ARGS__];       \
        NSLog(@"[adx] %@", adx_s__);                                             \
        printf("[adx] %s\n", adx_s__ ? adx_s__.UTF8String : "");                  \
        fflush(stdout);                                                          \
    } while (0)

/// 人类可读的字节数。
static inline NSString *ADXBytesText(unsigned long long n) {
    if (n < 1024) return [NSString stringWithFormat:@"%llu B", n];
    double v = (double)n;
    NSArray *units = @[ @"KB", @"MB", @"GB", @"TB" ];
    for (NSString *u in units) {
        v /= 1024.0;
        if (v < 1024.0) return [NSString stringWithFormat:@"%.1f %@", v, u];
    }
    return [NSString stringWithFormat:@"%.1f PB", v / 1024.0];
}