//
//  SKFMKit.h
//  AppDump — 文件管理器的公共件
//
//  照 lara 的 FileSystemHelpers.swift：剪贴板、可写判断、唯一路径、清不可变位、
//  删除、chmod / chown（POSIX 走不通时用 apfs_* 内核路径）。UI 组件（Get Info、
//  Create File）也放这里，文件和目录浏览器共用一个实现。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 剪贴板

@interface SKFMClipItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isDir;
@end

/// 复制/粘贴用的应用内剪贴板（不是系统剪贴板：跨应用传路径没有意义）。
@interface SKFMClipboard : NSObject
+ (instancetype)shared;
@property (nonatomic, strong, nullable) SKFMClipItem *item;
@end

#pragma mark - 文件操作

/// 目录是否可写。以 uid 501 的身份判 access(W_OK)：/var、/ 这类 UID=0 的目录
/// 返回 NO，UI 据此禁用写入、删除、重命名。
BOOL SKFMWritable(NSString *path);

/// 条目自己所在目录是否可写（删除/重命名改的是父目录）。
BOOL SKFMItemWritable(NSString *path);

/// 已存在时生成 "name copy.ext" / "name copy 2.ext"。
NSString *SKFMUniquePath(NSString *base);

void SKFMClearImmutable(NSString *path);

BOOL SKFMWriteData(NSString *path, NSData *data, NSError * _Nullable * _Nullable err);
BOOL SKFMCreateDirectory(NSString *path, NSError * _Nullable * _Nullable err);
BOOL SKFMRemoveItem(NSString *path, NSError * _Nullable * _Nullable err);
BOOL SKFMCopyItem(NSString *from, NSString *to, NSError * _Nullable * _Nullable err);
BOOL SKFMMoveItem(NSString *from, NSString *to, NSError * _Nullable * _Nullable err);

/// chmod：先 POSIX，失败且内核可读时走 apfs_mod（能改不属于自己的文件）。
BOOL SKFMChmod(NSString *path, unsigned int mode, BOOL isDir);
/// chown：先 POSIX，失败时走 apfs_own。
BOOL SKFMChown(NSString *path, unsigned int uid, unsigned int gid);

/// 统一风格的提示框。
UIAlertController *SKFMAlert(NSString *title, NSString *message);

#pragma mark - Get Info

/// 文件信息面板（lara 的 FileInfoSheet）。
@interface SKFMInfoViewController : UIViewController
- (instancetype)initWithPath:(NSString *)path;
@end

#pragma mark - Create File

/// 新建文件面板：文件名 + 内容（lara 的 santandernewfilesheet）。
@interface SKFMNewFileViewController : UIViewController
@property (nonatomic, copy) NSString *directory;
/// 成功后在主线程回调，参数是新建文件的完整路径。
@property (nonatomic, copy, nullable) void (^onCreated)(NSString *path);
@end

NS_ASSUME_NONNULL_END
