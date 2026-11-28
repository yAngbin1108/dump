//
//  SKIPAManager.h
//  AppDump — 「工具 → IPA 管理」
//
//  扫描沙盒 Documents 下所有的 .ipa（砸壳产物在 Documents/Decrypted，
//  其它来源的包可能直接放在 Documents 或某个子目录里），解析出包信息，
//  并提供删除 / 导出 / 改名等操作。
//
//  所有解析都在文件层面做：只读 IPA 的中央目录 + 每个条目的前 4KB，
//  不会解压整包，几百 MB 的包也是毫秒级。
//

#ifndef SKIPAMANAGER_H
#define SKIPAMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SKIPAIntegrity) {
    SKIPAIntegrityUnknown = 0,   // 不是合法 zip（截断 / 空文件 / 损坏）
    SKIPAIntegrityBroken,        // 是 zip，但缺少 Payload/*.app 或包内文件坏掉
    SKIPAIntegrityOk,            // 结构完整
};

/// 包内某个 Mach-O（主程序或扩展）的加密情况
@interface SKIPABinary : NSObject
@property (nonatomic, copy) NSString *path;          ///< 包内相对路径
@property (nonatomic, copy) NSString *archs;         ///< "arm64, arm64e"
@property (nonatomic, assign) BOOL encrypted;        ///< 任一切片 cryptid != 0
@property (nonatomic, assign) BOOL hasCryptInfo;     ///< 有 LC_ENCRYPTION_INFO(_2)
@property (nonatomic, assign) unsigned long long size;
@end

@interface SKIPA : NSObject
@property (nonatomic, copy) NSString *path;          ///< 磁盘上的绝对路径
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, assign) unsigned long long fileSize;
@property (nonatomic, copy) NSDate *modified;

// ── 从 Payload/*.app/Info.plist 读出来的 ──
@property (nonatomic, copy) NSString *appName;       ///< CFBundleDisplayName / CFBundleName
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *version;       ///< "1.2.3 (123)"
@property (nonatomic, copy) NSString *minimumOS;
@property (nonatomic, copy) NSString *executable;
@property (nonatomic, strong, nullable) UIImage *icon;

// ── 结构 ──
@property (nonatomic, assign) SKIPAIntegrity integrity;
@property (nonatomic, copy, nullable) NSString *problem;   ///< integrity != Ok 时的原因
@property (nonatomic, assign) NSUInteger entryCount;
@property (nonatomic, assign) unsigned long long uncompressedTotal;
@property (nonatomic, copy) NSArray<NSString *> *archs;    ///< 主程序 + 扩展里出现的全部架构
@property (nonatomic, strong) NSArray<SKIPABinary *> *binaries;
@property (nonatomic, strong) NSMutableArray<NSString *> *notes;  ///< 分析出来的提示

@property (nonatomic, assign) BOOL encrypted;              ///< 有任何一个二进制还是密文
@property (nonatomic, assign) BOOL signed;                 ///< 有 _CodeSignature/CodeResources
@property (nonatomic, assign) BOOL isCustomBundleID;       ///< bundle id 不属于 App Store 形态
@property (nonatomic, assign) BOOL hasWatchApp;
@property (nonatomic, assign) BOOL hasExtensions;
@property (nonatomic, assign) BOOL hasAppLessMain;         ///< 缺少主 Info.plist 等
@property (nonatomic, copy, nullable) NSString *extensionSummary; ///< "共享扩展 ×2、Widget ×1"
@property (nonatomic, copy, nullable) NSString *variant;   ///< "arm64e · 已解密" 之类的一行摘要

@property (nonatomic, assign) BOOL analyzed;               ///< 完整分析（含每个二进制）是否跑完
@end

#pragma mark - 扫描

/// Documents 根目录（ipa 的搜索起点）。
NSString *SKIPADocumentsPath(void);

/// 递归扫描 roots（默认就是 Documents）下所有 .ipa，按修改时间倒序。
NSArray<SKIPA *> *SKIPAScan(void);

/// 深分析：读 Info.plist、列 Mach-O、算完整性。可以在后台线程调用。
/// 轻量（不解压整包），但每个包仍要读几 KB～几百 KB。
void SKIPAAnalyze(SKIPA *ipa);

/// 只用文件名 / 大小 / 时间造一个条目（快速列表用）。
SKIPA *SKIPAMakeShallow(NSString *path);

#pragma mark - 操作

/// 删除一组 ipa 以及同名的 .plist / .app 目录等附属物。可在后台线程调用。
/// 返回的错误是 "文件名：原因" 形式，成功的不出现在里面。
NSArray<NSString *> *SKIPADelete(NSArray<SKIPA *> *items);

/// 重命名（只改文件名，保留 .ipa 后缀）。
BOOL SKIPARename(SKIPA *ipa, NSString *newName, NSError **error);

// ── 包内文件浏览（不解压，直接读 zip 条目） ──

/// 把包内路径列表压成「一级条目」：目录只出现一次，文件按原路径。
/// 例如传入 Payload/App.app/Frameworks/X.framework/X，返回
/// （level=1 时）Payload/App.app/Frameworks；已剥掉 prefix 那一段。
NSArray<NSDictionary<NSString *, id> *> *SKIPAListEntries(SKIPA *ipa,
                                                          NSString *prefix,
                                                          NSUInteger *totalOut);

/// 读包内一个条目的字节（最多 maxBytes）。stored / deflate 都会解开。
NSData * _Nullable SKIPAReadEntry(SKIPA *ipa, NSString *entry, NSUInteger maxBytes);

/// 所有包占用的总字节数。
unsigned long long SKIPATotalSize(NSArray<SKIPA *> *items);

/// 一行可读的摘要文本，用于详情页复制 / 分享。
NSString *SKIPAReportText(SKIPA *ipa);

NS_ASSUME_NONNULL_END

#endif /* SKIPAMANAGER_H */
