//
//  SKPathPolicy.m
//  Blade — 哪些路径允许改动
//

#import "SKPathPolicy.h"

#include <stdlib.h>
#include <limits.h>

static BOOL sk_prefix_ok(NSString *path) {
    // /var 是 /private/var 的软链，两种写法都要认（浏览时拿到哪种取决于入口）。
    static NSString * const kPrefixes[] = { @"/var", @"/private/var" };
    for (int i = 0; i < 2; i++) {
        NSString *p = kPrefixes[i];
        if ([path isEqualToString:p]) return YES;
        if ([path hasPrefix:[p stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

BOOL SKPathAllowsModify(NSString *path) {
    if (path.length == 0) return NO;

    // 先按字面判定（路径可能还不存在 —— 新建文件就是这种）。
    if (!sk_prefix_ok(path)) return NO;

    // 再按 realpath 解析一次。
    //
    // 只做字符串前缀判断是不够的：apfs_own / chmod 走的是 open()/chdir()，
    // 会跟随符号链接。只要 /var 下面有一条指向 /Applications 的软链，
    // "/var/xxx/Foo.app" 就能通过字面检查，而实际写到系统 app 的 vnode 上。
    // realpath 会把软链展开，展开后不在 /var 里就拒绝。
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) != NULL) {
        NSString *r = [NSString stringWithUTF8String:resolved];
        if (!sk_prefix_ok(r)) {
            NSLog(@"[policy] 拒绝改动: %@ 实际解析到 %@（在 /var 之外）", path, r);
            return NO;
        }
    }
    // realpath 失败（路径不存在 / 断链）时沿用字面判定 —— 新建文件属于这种，
    // 而新建的目标名里不含软链，字面判定足够。
    return YES;
}
