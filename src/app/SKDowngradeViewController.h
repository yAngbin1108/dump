//
//  SKDowngradeViewController.h
//  AppDump — 「工具 → 应用降级」
//
//  UI 流程：
//    选应用 → 取 Track ID（iTunes lookup，多区兜底）→ 取历史版本
//    （apis.bilin.eu.org/history/<trackId>）→ 选版本 → 注入 SpringBoard 提交请求
//    也支持直接填 external_identifier（AppExtVrsId）跳过版本列表。
//

#ifndef SKDOWNGRADEVIEWCONTROLLER_H
#define SKDOWNGRADEVIEWCONTROLLER_H

#import <UIKit/UIKit.h>

@interface SKDowngradeViewController : UITableViewController
@end

#endif /* SKDOWNGRADEVIEWCONTROLLER_H */
