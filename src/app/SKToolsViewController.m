//
//  SKToolsViewController.m
//  AppDump — 见 SKToolsViewController.h
//

#import "SKToolsViewController.h"
#import "ProcessListViewController.h"
#import "SKDowngradeViewController.h"
#import "SKBlockUpdatesViewController.h"
#import "ADXAppListViewController.h"
#import "SKIPAViewController.h"
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
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // 「砸壳」段：FairPlay 砸壳 + IPA 管理
    return section == 0 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"砸壳";
        case 1: return @"进程";
        case 2: return @"应用降级";
        default: return @"应用更新";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"借用 fairplayd 解密：把 SC_Info 的 SINF 补到每个加密二进制旁，"
                "再用 mremap_encrypted（cryptid 2，只读映射）让内核把密文页解开后回读。"
                "不需要内核漏洞，也不用启动目标 App。"
                "IPA 管理用来查看、分析、删除文档目录里的包（砸壳产物默认在 Decrypted 下）。";
    }
    if (section == 1) {
        return @"遍历内核 allproc 列出全部进程，可结束进程、编辑内存。需要先运行利用链。";
    }
    if (section == 2) {
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
            if (indexPath.row == 0) {
                cell.textLabel.text = @"FairPlay 砸壳";
                cell.detailTextLabel.text = @"fairplayd 解密，无需内核 / 不启动 App";
                cell.imageView.image = [UIImage systemImageNamed:@"lock.open.fill"];
            } else {
                cell.textLabel.text = @"IPA 管理";
                cell.detailTextLabel.text = @"分析 / 删除 / 多选删除 / 导出";
                cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
            }
            break;
        case 1:
            cell.textLabel.text = @"进程管理";
            cell.detailTextLabel.text = @"进程列表 / 结束进程 / 内存编辑";
            cell.imageView.image = [UIImage systemImageNamed:@"list.bullet.rectangle.fill"];
            break;
        case 2:
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
        case 0:
            vc = indexPath.row == 0 ? [ADXAppListViewController new] : [SKIPAViewController new];
            break;
        case 1: vc = [ProcessListViewController new]; break;
        case 2: vc = [SKDowngradeViewController new]; break;
        default: vc = [SKBlockUpdatesViewController new]; break;
    }
    if (vc) [self.navigationController pushViewController:vc animated:YES];
}

@end
