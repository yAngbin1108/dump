//
//  SKPathPolicy.h
//  Blade — 哪些路径允许改动
//
//  规则：只有 /var 与 /private/var 子树内允许修改，其余（/、/Applications、
//  /System、/bin …）一律只读，只能查看和进入目录。
//
//  为什么必须放在一个共享判定里、而不是散在各个菜单里：这条规则一开始只写在
//  文件管理器的菜单构建上，结果文本编辑器 / plist 编辑器的"保存"完全绕过了它 ——
//  浏览系统目录是允许的，从 /Applications/<X>.app/Info.plist 进去按保存，
//  内核路径就会把那个系统文件 chown 成 mobile。所以判定放在内核写入的收口处。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// path 是否允许做修改类操作（建/删/改名/chmod/chown/写入）。
BOOL SKPathAllowsModify(NSString * _Nullable path);

NS_ASSUME_NONNULL_END
