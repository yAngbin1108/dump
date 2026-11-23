#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 设置 → 修改偏移：列出 offsets.m 里的全部偏移，可逐个覆盖。
///
/// 覆盖值写在 exploit 自己读取的同一批 NSUserDefaults 键（lara.offset.<名>）里，
/// 所以「运行漏洞利用」时 offsets_init() 会带上它们，不需要重启 App。
@interface SKOffsetsViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
