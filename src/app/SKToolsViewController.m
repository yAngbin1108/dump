//
//  SKToolsViewController.m
//  AppDump — 见 SKToolsViewController.h
//

#import "SKToolsViewController.h"
#import "ProcessListViewController.h"
#import "SKDowngradeViewController.h"
#import "SKBlockUpdatesViewController.h"
#import "skrc.h"
#import "skdowngrade.h"

@implementation SKToolsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"工具";
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"进程";
        case 1: return @"应用降级";
        default: return @"应用更新";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"遍历内核 allproc 列出全部进程，可结束进程、编辑内存。需要先运行利用链。";
    }
    if (section == 1) {
        NSString *why = skdg_unsupported_reason();
        return why.length ? why
            : @"通过注入 SpringBoard，向 App Store 提交历史版本的下载请求。";
    }
    return @"在 .app 的父目录建立 com.apple.mobileinstallation.placeholder 目录（权限 0000），"
            "安装服务会把该应用当作「正在安装」而跳过更新。直接在本地执行，不注入进程。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"SKToolEntry";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    switch (indexPath.section) {
        case 0:
            cell.textLabel.text = @"进程管理";
            cell.detailTextLabel.text = @"进程列表 / 结束进程 / 内存编辑";
            cell.imageView.image = [UIImage systemImageNamed:@"list.bullet.rectangle.fill"];
            break;
        case 1:
            cell.textLabel.text = @"应用降级";
            cell.detailTextLabel.text = @"安装 App Store 上的历史版本";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
            break;
        default:
            cell.textLabel.text = @"阻止应用更新";
            cell.detailTextLabel.text = @"让选中的应用不再被 App Store 更新";
            cell.imageView.image = [UIImage systemImageNamed:@"nosign"];
            break;
    }
    cell.imageView.tintColor = self.view.tintColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    UIViewController *vc = nil;
    switch (indexPath.section) {
        case 0: vc = [ProcessListViewController new]; break;
        case 1: vc = [SKDowngradeViewController new]; break;
        default: vc = [SKBlockUpdatesViewController new]; break;
    }
    if (vc) [self.navigationController pushViewController:vc animated:YES];
}

@end
