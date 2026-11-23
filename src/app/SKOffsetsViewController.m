//
//  SKOffsetsViewController.m
//  AppDump — 设置 → 修改偏移
//

#import "SKOffsetsViewController.h"
#import "SKFMKit.h"
#import "SKLog.h"
#import "offsets.h"

@interface SKOffsetsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *query;
@end

@implementation SKOffsetsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"修改偏移";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 44;
    [self.view addSubview:self.table];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索偏移名";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全部重置"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(resetAll)];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

#pragma mark - 数据

- (NSArray<NSNumber *> *)indices {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    NSString *q = [self.query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for (size_t i = 0; i < skoffs_count(); i++) {
        const char *name = skoffs_name(i);
        if (!name) continue;
        if (q.length && ![[NSString stringWithUTF8String:name] localizedCaseInsensitiveContainsString:q]) continue;
        [out addObject:@(i)];
    }
    return out;
}

#pragma mark - 列表

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)[self indices].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"共 %zu 个偏移，已覆盖 %zu 个", skoffs_count(), skoffs_override_count()];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"点一行改数值（支持 0x 十六进制），点“重置”取消这一项的覆盖。改动会在下次运行漏洞利用时生效。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"o";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];

    size_t idx = [[self indices][ip.row] unsignedLongValue];
    const char *name = skoffs_name(idx);
    uint64_t value = skoffs_value(idx);
    BOOL is64 = skoffs_is64(idx);
    BOOL over = skoffs_overridden(idx);

    UIListContentConfiguration *cc = [c defaultContentConfiguration];
    cc.text = [NSString stringWithUTF8String:name];
    cc.textProperties.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    cc.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    cc.textProperties.color = over ? UIColor.systemOrangeColor : UIColor.labelColor;
    c.contentConfiguration = cc;

    UILabel *val = [[UILabel alloc] init];
    val.text = is64 ? [NSString stringWithFormat:@"0x%llx", value] : [NSString stringWithFormat:@"0x%x", (unsigned)value];
    val.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    val.textColor = over ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    [val sizeToFit];
    c.accessoryView = val;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    size_t idx = [[self indices][ip.row] unsignedLongValue];
    [self editIndex:idx];
}

- (void)editIndex:(size_t)idx {
    const char *name = skoffs_name(idx);
    if (!name) return;

    BOOL is64 = skoffs_is64(idx);
    uint64_t value = skoffs_value(idx);
    NSString *current = is64 ? [NSString stringWithFormat:@"0x%llx", value]
                             : [NSString stringWithFormat:@"0x%x", (unsigned)value];

    UIAlertController *al = [UIAlertController alertControllerWithTitle:[NSString stringWithUTF8String:name]
                                                               message:[NSString stringWithFormat:@"当前值 %@", current]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current;
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [al addAction:[UIAlertAction actionWithTitle:@"应用" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *text = [al.textFields.firstObject.text
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        unsigned long long v = 0;
        NSScanner *sc = [NSScanner scannerWithString:text.lowercaseString];
        if ([text.lowercaseString hasPrefix:@"0x"]) {
            [sc scanString:@"0x" intoString:NULL];
            [sc scanHexLongLong:&v];
        } else {
            [sc scanUnsignedLongLong:&v];
        }
        if (!text.length || sc.isAtEnd == NO) {
            [self presentViewController:SKFMAlert(@"无效的数值", @"请输入十六进制（0x 开头）或十进制整数。")
                               animated:YES completion:nil];
            return;
        }
        if (!is64 && v > 0xffffffffULL) {
            [self presentViewController:SKFMAlert(@"数值过大", @"这是 32 位偏移，最大 0xffffffff。")
                               animated:YES completion:nil];
            return;
        }
        skoffs_set(idx, (uint64_t)v);
        SKLog(@"[offs] user set %s = 0x%llx", name, (unsigned long long)v);
        [self.table reloadData];
    }]];
    if (skoffs_overridden(idx)) {
        [al addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
            skoffs_reset(idx);
            SKLog(@"[offs] user reset %s", name);
            [self.table reloadData];
        }]];
    }
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)resetAll {
    if (!skoffs_override_count()) {
        [self presentViewController:SKFMAlert(@"没有覆盖项", @"现在没有任何偏移被改过。")
                           animated:YES completion:nil];
        return;
    }
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"全部重置"
                                                               message:@"把所有被改过的偏移恢复成默认值？"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        skoffs_reset_all();
        SKLog(@"[offs] user reset all overrides");
        [self.table reloadData];
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)c {
    self.query = c.searchBar.text;
    [self.table reloadData];
}

@end
