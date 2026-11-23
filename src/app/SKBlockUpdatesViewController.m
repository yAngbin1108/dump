//
//  SKBlockUpdatesViewController.m
//  AppDump — 见 SKBlockUpdatesViewController.h
//

#import "SKBlockUpdatesViewController.h"
#import "SKToolApps.h"
#import "SKToolLogViewController.h"
#import "skblockupdates.h"
#import "darksword.h"

@interface SKBlockUpdatesViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<SKToolApp *> *apps;
@property (nonatomic, strong) NSArray<SKToolApp *> *filtered;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIBarButtonItem *applyItem;
@end

@implementation SKBlockUpdatesViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"阻止应用更新";
    self.selected = [NSMutableSet set];
    self.filtered = @[];

    _applyItem = [[UIBarButtonItem alloc] initWithTitle:@"应用"
                                                  style:UIBarButtonItemStyleDone
                                                 target:self
                                                 action:@selector(applyTapped)];
    _applyItem.enabled = NO;
    self.navigationItem.rightBarButtonItem = _applyItem;

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    self.tableView.backgroundView = _spinner;
    [_spinner startAnimating];

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(handleRefresh:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refresh;

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"搜索应用";
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [self loadApps];
}

- (void)handleRefresh:(UIRefreshControl *)refresh {
    [self loadApps];
    [refresh endRefreshing];
}

- (void)loadApps {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<SKToolApp *> *apps = SKToolLoadApps(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            self.filtered = apps;
            // 掉线（应用被卸载）的选中项清掉
            NSMutableSet *alive = [NSMutableSet set];
            for (SKToolApp *a in apps) {
                if ([self.selected containsObject:a.bundleID]) [alive addObject:a.bundleID];
            }
            self.selected = alive;
            [self.spinner stopAnimating];
            self.tableView.backgroundView = apps.count ? nil : [self emptyLabel];
            [self updateApplyButton];
            [self.tableView reloadData];
        });
    });
}

- (UILabel *)emptyLabel {
    UILabel *l = [UILabel new];
    l.text = @"没有找到可操作的应用";
    l.textColor = UIColor.secondaryLabelColor;
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

#pragma mark - 搜索

- (BOOL)isFiltering {
    return self.searchController.isActive && self.searchController.searchBar.text.length > 0;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text;
    if (text.length == 0) {
        self.filtered = self.apps;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(SKToolApp *app, NSDictionary *bindings) {
            return [app.name localizedCaseInsensitiveContainsString:text]
                || [app.bundleID localizedCaseInsensitiveContainsString:text];
        }];
        self.filtered = [self.apps filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

- (void)updateApplyButton {
    self.applyItem.enabled = self.selected.count > 0;
    self.applyItem.title = self.selected.count
        ? [NSString stringWithFormat:@"应用(%lu)", (unsigned long)self.selected.count]
        : @"应用";
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)(self.isFiltering ? self.filtered.count : self.apps.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"勾选应用，再点右上角「应用」";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"勾选后点右上角「应用」，选择阻止或恢复。目录在本地建立（必要时用内核修父目录属主），"
            "不需要注入进程。已阻止的应用在 App Store 里仍会显示「更新」，但不会真的装上。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"app";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }
    SKToolApp *app = (self.isFiltering ? self.filtered : self.apps)[indexPath.row];
    cell.textLabel.text = app.name;
    cell.imageView.image = app.icon ?: [UIImage systemImageNamed:@"app.dashed"];

    BOOL blocked = app.blocked;
    BOOL waiting = [self.selected containsObject:app.bundleID];
    if (waiting) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  已选中", app.bundleID];
        cell.detailTextLabel.textColor = UIColor.systemOrangeColor;
    } else if (blocked) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  已阻止更新 🚫", app.bundleID];
        cell.detailTextLabel.textColor = UIColor.systemRedColor;
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  v%@", app.bundleID, app.version];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    }
    cell.accessoryType = waiting ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SKToolApp *app = (self.isFiltering ? self.filtered : self.apps)[indexPath.row];
    if ([self.selected containsObject:app.bundleID]) {
        [self.selected removeObject:app.bundleID];
    } else {
        [self.selected addObject:app.bundleID];
    }
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
    [self updateApplyButton];
    [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationFade];
}

#pragma mark - 执行

- (void)applyTapped {
    if (self.selected.count == 0) return;

    NSArray<SKToolApp *> *targets = [self.apps filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(SKToolApp *app, NSDictionary *b) {
            return [self.selected containsObject:app.bundleID];
        }]];

    NSInteger blockedCount = 0;
    for (SKToolApp *a in targets) if (a.blocked) blockedCount++;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"已选 %lu 个应用", (unsigned long)targets.count]
        message:[NSString stringWithFormat:@"其中 %ld 个已阻止更新。要做什么？", (long)blockedCount]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"阻止更新" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self runForTargets:targets block:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"恢复更新" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self runForTargets:targets block:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        && sheet.popoverPresentationController) {
        sheet.popoverPresentationController.barButtonItem = self.applyItem;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)runForTargets:(NSArray<SKToolApp *> *)targets block:(BOOL)block {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (SKToolApp *a in targets) {
        [paths addObject:a.placeholderPath];
        [names addObject:a.name];
    }

    SKToolLogViewController *logVC =
        [[SKToolLogViewController alloc] initWithTitle:(block ? @"阻止更新" : @"恢复更新")];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    __weak typeof(self) weakSelf = self;
    [self presentViewController:nav animated:YES completion:^{
        [logVC setStatusText:@"正在等待 installd…"];
        [logVC appendLine:[NSString stringWithFormat:@"%@ %lu 个应用：%@",
                           block ? @"阻止" : @"恢复", (unsigned long)targets.count,
                           [names componentsJoinedByString:@", "]]];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int rc = skbu_apply(paths, block, ^(NSString *line) {
                [logVC appendLine:line];
            }, ^(NSInteger done, NSInteger total) {
                [logVC setStatusText:[NSString stringWithFormat:@"进度 %ld / %ld", (long)done, (long)total]];
            });

            NSString *msg;
            switch (rc) {
                case 0:  msg = @"全部完成"; break;
                case 1:  msg = @"内核未就绪"; break;
                case 2:  msg = @"无法附着 installd（未被唤醒）"; break;
                case 3:  msg = @"部分失败"; break;
                case 20: msg = @"当前构建不支持注入"; break;
                case 98: msg = @"超时"; break;
                default: msg = [NSString stringWithFormat:@"失败（%d）", rc]; break;
            }
            NSString *detail = skbu_last_error();
            if (rc != 0 && rc != 3 && detail.length) msg = [msg stringByAppendingFormat:@"：%@", detail];

            dispatch_async(dispatch_get_main_queue(), ^{
                [logVC finishWithSuccess:(rc == 0 || rc == 3) message:msg];
                [weakSelf.selected removeAllObjects];
                [weakSelf updateApplyButton];
                [weakSelf loadApps];       // 刷新 🚫 状态
            });
        });
    }];
}

@end
