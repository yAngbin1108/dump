#import <UIKit/UIKit.h>

@interface FileManagerViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong, readonly) NSString *currentPath;
@property (nonatomic, strong, readonly) UITableView *tableView;
@property (nonatomic, strong, readonly) NSMutableArray *fileList;
- (instancetype)initWithPath:(NSString *)path;

/// 「上一级」能不能越出入口路径。
///
/// 默认 NO：从主菜单进文件管理器时入口是 /var，越出它一步就跳到 "/"，
/// 这不是用户想要的（反馈："在 var 下会直接回退到根目录"）。
/// App 管理器跳进某个 .app 的场景把它设成 YES —— 那里用户明确要看父目录。
@property (nonatomic, assign) BOOL allowEscapeAboveRoot;
/// Zip `srcPath` into `dstPath`. Exposed so other screens (e.g. the
/// decryption view) can package an app bundle into an .ipa.
FOUNDATION_EXPORT NSString *zipPathTo(NSString *srcPath, NSString *dstPath);

@end
