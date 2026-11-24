//
//  ADXAppListViewController.m
//  App 扩展层 — 选择要砸壳的应用（FairPlay 引擎）
//
#import "ADXAppListViewController.h"
#import "ADXJobViewController.h"
#import "ADXApps.h"
#import "ADXInternal.h"

@interface ADXAppListViewController ()
@property (nonatomic, strong) NSArray<ADXApp *> *userApps;
@property (nonatomic, strong) NSArray<ADXApp *> *systemApps;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation ADXAppListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择应用";
    self.tableView.rowHeight = 56;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
    [self.spinner startAnimating];

    [self reload];
}

- (void)reload {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<ADXApp *> *all = ADXScanInstalledApps();
        NSMutableArray *user = [NSMutableArray array];
        NSMutableArray *sys = [NSMutableArray array];
        for (ADXApp *a in all) {
            if (a.isSystem) [sys addObject:a]; else [user addObject:a];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.userApps = user;
            strongSelf.systemApps = sys;
            [strongSelf.spinner stopAnimating];
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return self.userApps.count ? @"用户应用" : nil;
    return self.systemApps.count ? @"系统应用" : nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (s == 0 ? self.userApps : self.systemApps).count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"adxapp";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    ADXApp *a = (ip.section == 0 ? self.userApps : self.systemApps)[ip.row];
    cell.textLabel.text = a.name;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = a.bundleID;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    ADXApp *a = (ip.section == 0 ? self.userApps : self.systemApps)[ip.row];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:a.name
                                                                  message:a.bundleID
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"FairPlay 砸壳（无需内核）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
        BOOL relax = [NSUserDefaults.standardUserDefaults boolForKey:@"adx.relax"];
        ADXJobViewController *vc = [[ADXJobViewController alloc] initWithApp:a relaxInstallRestrictions:relax];
        [weakSelf.navigationController pushViewController:vc animated:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = tv;
    sheet.popoverPresentationController.sourceRect = [tv rectForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end