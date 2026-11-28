//
//  SKIPAFilesViewController.h
//  AppDump — 包内文件浏览（只读，按需解压单个条目）
//

#ifndef SKIPAFILESVIEWCONTROLLER_H
#define SKIPAFILESVIEWCONTROLLER_H

#import <UIKit/UIKit.h>
#import "SKIPAManager.h"

@interface SKIPAFilesViewController : UITableViewController

- (instancetype)initWithIPA:(SKIPA *)ipa prefix:(NSString *)prefix;

@end

#endif /* SKIPAFILESVIEWCONTROLLER_H */
