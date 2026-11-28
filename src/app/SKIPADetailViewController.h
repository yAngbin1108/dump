//
//  SKIPADetailViewController.h
//  AppDump — IPA 详情 / 分析结果
//

#ifndef SKIPADETAILVIEWCONTROLLER_H
#define SKIPADETAILVIEWCONTROLLER_H

#import <UIKit/UIKit.h>
#import "SKIPAManager.h"

@interface SKIPADetailViewController : UITableViewController

- (instancetype)initWithIPA:(SKIPA *)ipa;

/// 在详情页里删除成功后回调，列表页据此移除该行。
@property (nonatomic, copy, nullable) void (^onDeleted)(SKIPA *ipa);

@end

#endif /* SKIPADETAILVIEWCONTROLLER_H */
