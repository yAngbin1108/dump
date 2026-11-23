//
//  SKDowngradeViewController.m
//  AppDump — 见 SKDowngradeViewController.h
//

#import "SKDowngradeViewController.h"
#import "SKToolApps.h"
#import "SKToolLogViewController.h"
#import "skdowngrade.h"
#import "skrc.h"

@interface SKDowngradeViewController (Runner)
+ (void)runDowngradeWithTrackId:(long long)trackId
                      versionId:(long long)versionId
                     lookupJSON:(NSString *)lookupJSON
                        appName:(NSString *)appName
                           host:(UIViewController *)host;
@end

#pragma mark - 版本选择页

/// 历史版本接口用 created_at，早期接口用 release_date，两者都认。
static NSString *SKVersionDateString(NSDictionary *v) {
    for (NSString *key in @[ @"created_at", @"release_date" ]) {
        NSString *d = [v[key] description];
        if (d.length) return d;
    }
    return @"";
}

@interface SKVersionPickerViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary *> *versions;
@property (nonatomic, assign) long long trackId;
@property (nonatomic, copy) NSString *lookupJSON;
@property (nonatomic, copy) NSString *appName;
@end

@implementation SKVersionPickerViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择版本";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.versions.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"%@ 的历史版本（共 %lu 个）",
            self.appName ?: @"应用", (unsigned long)self.versions.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"version";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *v = self.versions[indexPath.row];
    NSString *bundleVersion = [v[@"bundle_version"] description] ?: @"?";
    NSString *extId = [v[@"external_identifier"] description] ?: @"";
    NSString *date = SKVersionDateString(v);
    cell.textLabel.text = bundleVersion;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID %@%@", extId,
                                 date.length ? [@"  ·  " stringByAppendingString:date] : @""];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *v = self.versions[indexPath.row];
    long long versionId = [[v[@"external_identifier"] description] longLongValue];
    if (versionId <= 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"版本 ID 无效"
                                                                  message:@"这条历史版本没有可用的 external_identifier。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [SKDowngradeViewController runDowngradeWithTrackId:self.trackId
                                            versionId:versionId
                                           lookupJSON:self.lookupJSON
                                              appName:self.appName
                                                 host:self];
}

@end

#pragma mark - 降级页

@interface SKDowngradeViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<SKToolApp *> *apps;
@property (nonatomic, strong) NSArray<SKToolApp *> *filtered;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation SKDowngradeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"应用降级";
    self.filtered = @[];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    self.tableView.backgroundView = _spinner;
    [_spinner startAnimating];

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"搜索应用";
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [self loadApps];
}

- (void)loadApps {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<SKToolApp *> *apps = SKToolLoadApps(NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = apps;
            self.filtered = apps;
            [self.spinner stopAnimating];
            self.tableView.backgroundView = apps.count ? nil : [self emptyLabel];
            [self.tableView reloadData];
        });
    });
}

- (UILabel *)emptyLabel {
    UILabel *l = [UILabel new];
    l.text = @"没有找到可降级的应用";
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

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)(self.isFiltering ? self.filtered.count : self.apps.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *why = skdg_unsupported_reason();
    if (why.length) {
        return [NSString stringWithFormat:@"可以查询版本，但暂时无法执行：%@", why];
    }
    return @"版本列表由第三方接口提供，只需要其中的 external_identifier；确认后由 App Store 下载。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"app";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    SKToolApp *app = (self.isFiltering ? self.filtered : self.apps)[indexPath.row];
    cell.textLabel.text = app.name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  v%@", app.bundleID, app.version];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = app.icon ?: [UIImage systemImageNamed:@"app.dashed"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SKToolApp *app = (self.isFiltering ? self.filtered : self.apps)[indexPath.row];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:app.name
                                                                  message:@"选择获取版本 ID 的方式"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"从服务器获取历史版本"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf fetchVersionsForApp:app];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"手动输入版本 ID"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf promptCustomVersionForApp:app];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        && sheet.popoverPresentationController) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds
            : CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 取 Track ID / 版本

// 多区兜底：很多 App 在某些区没有条目，逐个试。
static NSArray<NSString *> *SKDowngradeCountryCodes(void) {
    return @[ @"cn", @"us", @"hk", @"tw", @"jp", @"kr", @"sg", @"gb", @"de", @"fr",
              @"ca", @"au", @"it", @"es", @"nl", @"ru", @"in", @"br", @"mx", @"tr" ];
}

- (void)fetchVersionsForApp:(SKToolApp *)app {
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"查询中"
                                                                    message:[NSString stringWithFormat:@"正在查找 %@ 的 Track ID…", app.name]
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    NSArray<NSString *> *countries = SKDowngradeCountryCodes();
    __weak typeof(self) weakSelf = self;
    [self fetchTrackIdForBundle:app.bundleID countries:countries index:0
                     completion:^(long long trackId, NSDictionary *entry, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (trackId <= 0 || !entry) {
                [loading dismissViewControllerAnimated:YES completion:^{
                    [weakSelf showError:@"找不到 Track ID"
                                message:[NSString stringWithFormat:
                                         @"iTunes 在 %lu 个区里都没有查到这个应用。可以改用手动输入版本 ID。",
                                         (unsigned long)countries.count]];
                }];
                return;
            }
            loading.message = @"正在获取历史版本…";
            [weakSelf fetchVersionsForTrackId:trackId completion:^(NSArray<NSDictionary *> *versions, NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [loading dismissViewControllerAnimated:YES completion:^{
                        if (versions.count == 0) {
                            [weakSelf showError:@"没有历史版本"
                                        message:e.localizedDescription ?: @"服务器没有返回任何旧版本。"];
                            return;
                        }
                        [weakSelf presentVersionPicker:versions trackId:trackId entry:entry app:app];
                    }];
                });
            }];
        });
    }];
}

- (void)fetchTrackIdForBundle:(NSString *)bundleID
                    countries:(NSArray<NSString *> *)countries
                        index:(NSInteger)index
                   completion:(void (^)(long long trackId, NSDictionary *entry, NSError *err))completion
{
    if (index >= (NSInteger)countries.count) {
        if (completion) completion(0, nil, [NSError errorWithDomain:@"SKDowngrade" code:404
                                                           userInfo:@{NSLocalizedDescriptionKey:
                                                           @"App not found in any supported storefront."}]);
        return;
    }
    NSString *cc = countries[index];
    NSString *urlStr = [NSString stringWithFormat:
        @"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software&country=%@",
        bundleID, cc];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.timeoutInterval = 12.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
        if ([results isKindOfClass:[NSArray class]] && results.count > 0
            && [results.firstObject isKindOfClass:[NSDictionary class]]) {
            NSDictionary *entry = results.firstObject;
            long long trackId = [entry[@"trackId"] longLongValue];
            if (trackId > 0) {
                if (completion) completion(trackId, entry, nil);
                return;
            }
        }
        [self fetchTrackIdForBundle:bundleID countries:countries index:index + 1 completion:completion];
    }] resume];
}

- (void)fetchVersionsForTrackId:(long long)trackId
                     completion:(void (^)(NSArray<NSDictionary *> *versions, NSError *err))completion
{
    NSString *urlStr = [NSString stringWithFormat:@"https://apis.bilin.eu.org/history/%lld", trackId];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.timeoutInterval = 15.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        if (!data) {
            if (completion) completion(@[], e ?: [NSError errorWithDomain:@"SKDowngrade" code:1 userInfo:nil]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *list = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        if (![list isKindOfClass:[NSArray class]]) list = @[];
        NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
        NSMutableSet<NSString *> *seenVersion = [NSMutableSet set];
        for (id v in list) {
            if (![v isKindOfClass:[NSDictionary class]]) continue;
            if ([v[@"external_identifier"] description].length == 0) continue;
            // 同一版本号在不同区会出现多条，只留第一条（列表已按发布时间倒序）
            NSString *ver = [v[@"bundle_version"] description] ?: @"";
            if (ver.length) {
                if ([seenVersion containsObject:ver]) continue;
                [seenVersion addObject:ver];
            }
            [filtered addObject:v];
        }
        [filtered sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
            return [SKVersionDateString(y) compare:SKVersionDateString(x)];
        }];
        if (completion) completion(filtered, nil);
    }] resume];
}

- (void)presentVersionPicker:(NSArray<NSDictionary *> *)versions
                     trackId:(long long)trackId
                       entry:(NSDictionary *)entry
                         app:(SKToolApp *)app
{
    SKVersionPickerViewController *picker = [SKVersionPickerViewController new];
    picker.versions = versions;
    picker.trackId = trackId;
    picker.appName = app.name;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    picker.lookupJSON = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
    [self.navigationController pushViewController:picker animated:YES];
}

#pragma mark - 手动版本 ID

- (void)promptCustomVersionForApp:(SKToolApp *)app {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"版本 ID"
                                                                  message:@"输入目标版本的 external_identifier（AppExtVrsId，纯数字）。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.placeholder = @"例如 843219482";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"降级" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        long long versionId = alert.textFields.firstObject.text.longLongValue;
        if (versionId <= 0) {
            [weakSelf showError:@"版本 ID 无效" message:@"需要纯数字的 external_identifier。"];
            return;
        }
        [weakSelf resolveTrackIdThenRunForApp:app versionId:versionId];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resolveTrackIdThenRunForApp:(SKToolApp *)app versionId:(long long)versionId {
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"查询中"
                                                                    message:@"正在查找 Track ID…"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];
    __weak typeof(self) weakSelf = self;
    [self fetchTrackIdForBundle:app.bundleID countries:SKDowngradeCountryCodes() index:0
                     completion:^(long long trackId, NSDictionary *entry, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (trackId <= 0) {
                    [weakSelf showError:@"找不到 Track ID"
                                message:@"这个应用在 iTunes 里查不到，无法提交降级请求。"];
                    return;
                }
                NSData *jsonData = entry ? [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil] : nil;
                NSString *lookupJSON = jsonData ? [[NSString alloc] initWithData:jsonData
                                                                        encoding:NSUTF8StringEncoding] : nil;
                [SKDowngradeViewController runDowngradeWithTrackId:trackId
                                                        versionId:versionId
                                                       lookupJSON:lookupJSON
                                                          appName:app.name
                                                             host:weakSelf];
            }];
        });
    }];
}

#pragma mark - 执行

+ (void)runDowngradeWithTrackId:(long long)trackId
                      versionId:(long long)versionId
                     lookupJSON:(NSString *)lookupJSON
                        appName:(NSString *)appName
                           host:(UIViewController *)host
{
    SKToolLogViewController *logVC =
        [[SKToolLogViewController alloc] initWithTitle:[NSString stringWithFormat:@"降级 %@", appName ?: @""]];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    [host presentViewController:nav animated:YES completion:^{
        NSString *why = skdg_unsupported_reason();
        if (why.length) {
            [logVC appendLine:why];
            [logVC finishWithSuccess:NO message:@"降级不可用"];
            return;
        }
        [logVC setStatusText:@"正在注入 SpringBoard…"];
        [logVC appendLine:[NSString stringWithFormat:@"目标：%@  trackId=%lld  versionId=%lld",
                           appName ?: @"", trackId, versionId]];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int rc = skdg_perform_downgrade(trackId, versionId, lookupJSON, ^(NSString *line) {
                [logVC appendLine:line];
            });
            NSString *msg;
            switch (rc) {
                case 0:  msg = @"请求已提交"; break;
                case 1:  msg = @"内核未就绪"; break;
                case 20: msg = @"注入失败"; break;
                case 30: msg = @"当前系统不支持注入"; break;
                case 98: msg = @"超时"; break;
                default: msg = [NSString stringWithFormat:@"失败（%d）", rc]; break;
            }
            NSString *detail = skdg_last_error();
            if (rc != 0 && detail.length) msg = [msg stringByAppendingFormat:@"：%@", detail];
            dispatch_async(dispatch_get_main_queue(), ^{
                [logVC finishWithSuccess:(rc == 0) message:msg];
            });
        });
    }];
}

#pragma mark - 提示

- (void)showError:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                              message:message
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
