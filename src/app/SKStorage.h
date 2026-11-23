//
//  SKStorage.h
//  Blade — Documents 目录的清理
//
//  Blade 只用 Documents 存东西（日志、内核缓存、砸壳产物），其中有两类会
//  随着使用无限长大：
//
//    * Documents/Decrypted/.tmp_<bundleID>/  —— 砸壳前对目标 App 的整份拷贝。
//      正常流程最后会删掉，但打包/移动失败的几条 return 路径漏了删，而且
//      如果过程中 App 被系统回收（jetsam）或被重启，它就会永远留在那里。
//      一份就是几百 MB 到几个 GB，用几次就能把沙盒撑爆。
//
//    * Documents/lara.log —— 每次内核读写的诊断都往里追加，没有上限。
//
//  所以启动时清一次：残留的工作目录直接删掉（启动时不可能有正在跑的砸壳），
//  过大的日志截断。
//

#ifndef SKStorage_h
#define SKStorage_h

#import <Foundation/Foundation.h>

// 清掉砸壳残留的工作目录，返回释放的字节数。
unsigned long long SKStorageRemoveDecryptWorkDirs(void);

// 启动时调用：上面那些 + 日志截断。幂等，开销很小。
void SKStorageSweepOnLaunch(void);

// 目录（含子目录）占用的字节数，递归。
unsigned long long SKStorageDirectorySize(NSString *path);

// Documents 下 Blade 自己产生的文件一共占多少字节。
unsigned long long SKStorageOwnFootprint(void);

#endif /* SKStorage_h */
