//
//  SKPermRepair.h
//  AppDump — 权限修复（完全照 blade 的算法）
//
//  blade 的思路（FileManager.m）分两层：
//
//   1) **进入目录时整树修一次**：每次列目录，如果这个路径落在某个 `*.app` 里，
//      就在后台把那个 bundle 整体 chown 成 mobile(501)（用 apfs_own_tree，
//      它在内核里直接写 APFS inode，不进 vnode_authorize）。每个 bundle 只做一次，
//      失败会撤销标记以便下次重试。目录的写权限才是关键，只改单个文件没用。
//
//   2) **操作失败时按需修**：建/删/改名/写入失败后，先确认不是 DAC 问题 ——
//      调 APFS 层把这个路径（以及做落盘操作时需要的父目录）的属主/权限修成
//      mobile 可写，然后**重试一次**；还失败才报错。
//
//  两条路径都只对 /var 与 /private/var 子树生效（SKPathAllowsModify），
//  系统目录永不动；整树 chown 内部会跳过 _CodeSignature / SC_Info。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 按需修复单个路径的属主/权限（必要时连父目录一起）。
/// 已经是我们且可写时零内核写。路径不在可改区内直接返回 NO。
BOOL SKPermissionRepair(NSString *path);

/// 只要父目录可写（建文件/粘贴/改名需要）。
BOOL SKPermissionRepairParent(NSString *path);

/// 进入某个目录时调用：若该路径落在 .app 内，后台把整个 bundle 整树 chown 一次。
/// 每个 bundle 一次；失败自动撤销标记，下次还会试。
void SKPermissionRepairForDirectory(NSString *dirPath);

/// 还给"整树 chown 做过哪些 bundle"用（调试/日志）。
BOOL SKPermissionHasRepairedAppTree(NSString *appRoot);

NS_ASSUME_NONNULL_END
