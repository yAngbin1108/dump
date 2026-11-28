//
//  SKIPAViewController.m
//  AppDump — IPA 管理列表（多选 / 删除 / 分析 / 导出）
//
//  扫描范围是文档目录（Documents，包含砸壳产物 Documents/Decrypted）。
//  列表先按文件名快速出来，随后在后台逐个深分析（Info.plist、架构、
//  cryptid、签名），分析完成的格子会就地刷新。
//
#import "SKIPAViewController.h"
#import "SKIPADetailViewController.h"
#import "SKIPAManager.h"
#import "ADXInternal.h"
#import "SKLoc.h"

@interface SKIPAViewController ()
@property (nonatomic, strong) NSMutableArray<SKIPA *> *allItems;
@property (nonatomic, strong) NSArray<SKIPA *> *items;          // 当前筛选后的
@property (nonatomic, assign) NSInteger filter;                 // 0 全部 1 已解密 2 未解密 3 结构异常
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic, assign) BOOL scanning;
@property (nonatomic, assign) BOOL hasAppeared;
@end

@implementation SKIPAViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IPA 管理";
    self.tableView.rowHeight = 64;

    self.allItems = [NSMutableArray array];
    self.items = @[];
    self.queue = [NSOperationQueue new];
    self.queue.maxConcurrentOperationCount = 1;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"选择"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(toggleEditing)];

    self.tableView.refreshControl = [[UIRefreshControl alloc] init];
    [self.tableView.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从详情页回来可能删过东西：数组和磁盘对不上时补一次重扫。
    // 首次显示由 viewDidLoad 的 reload 负责，这里直接放行，避免重复扫描。
    if (self.hasAppeared && !self.isEditing && !self.scanning) [self checkDiskChanged];
    self.hasAppeared = YES;
}

/// 只比较数量与文件名集合，避免每次返回都全量 stat 一遍大包。
- (void)checkDiskChanged {
    NSArray<SKIPA *> *now = SKIPAScan();
    if (now.count == self.allItems.count) return;
    self.allItems = [now mutableCopy];
    [self applyFilter];
    [self.tableView reloadData];
    [self analyzeInBackground];
}

#pragma mark - 载入

- (void)reload {
    if (self.scanning) return;
    self.scanning = YES;
    [self.spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<SKIPA *> *scanned = SKIPAScan();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.scanning = NO;
            [strongSelf.queue cancelAllOperations];
            strongSelf.allItems = [scanned mutableCopy];
            [strongSelf applyFilter];
            [strongSelf.spinner stopAnimating];
            [strongSelf.tableView.refreshControl endRefreshing];
            [strongSelf.tableView reloadData];
            [strongSelf analyzeInBackground];
        });
    });
}

- (void)applyFilter {
    if (self.filter == 0) {
        self.items = self.allItems.copy;
        return;
    }
    NSMutableArray<SKIPA *> *out = [NSMutableArray array];
    for (SKIPA *ipa in self.allItems) {
        if (!ipa.analyzed) { [out addObject:ipa]; continue; }   // 还没分析完的先保留
        switch (self.filter) {
            case 1: if (!ipa.encrypted && ipa.binaries.count) [out addObject:ipa]; break;
            case 2: if (ipa.encrypted) [out addObject:ipa]; break;
            case 3: if (ipa.integrity != SKIPAIntegrityOk) [out addObject:ipa]; break;
            default: [out addObject:ipa]; break;
        }
    }
    self.items = out;
}

- (void)analyzeInBackground {
    NSArray<SKIPA *> *snapshot = self.allItems.copy;
    __weak typeof(self) weakSelf = self;
    for (SKIPA *ipa in snapshot) {
        [self.queue addOperationWithBlock:^{
            SKIPAAnalyze(ipa);
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                // 不要用 reloadRowsAtIndexPaths：分析是异步的，表格的行数可能已经从 0 变成 1
                // （扫描回来时是空、分析完成时已经有包），这种「行数变化 + 单行刷新」会让
                // UITableView 认为更新前后行数不一致而抛 NSInternalInconsistencyException。
                // 整表重载是原子操作，也不会把选中状态之外的编辑态打乱。
                if (strongSelf.allItems.count == 0) return;
                [strongSelf.tableView reloadData];
            });
        }];
    }
}

- (NSInteger)rowForPath:(NSString *)path {
    for (NSUInteger i = 0; i < self.items.count; i++) {
        if ([self.items[i].path isEqualToString:path]) return (NSInteger)i;
    }
    return -1;
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return nil;
    if (!self.items.count) {
        return [self.allItems count] ? @"当前筛选下没有包" : nil;
    }
    return [NSString stringWithFormat:@"%lu 个包 · %@", (unsigned long)self.items.count,
            ADXBytesText(SKIPATotalSize(self.items))];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s != 0) return nil;
    if (!self.allItems.count && !self.spinner.isAnimating) {
        return @"文档目录里还没有 .ipa。砸壳完成的包会自动出现在这里；"
                "也可以通过「文件」App / 其它 App 的「用 App 打开」把包拷进来。";
    }
    return @"扫描范围为 App 的文档目录（含 Decrypted）。左滑删除，右上「选择」可多选批量删除。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *summaryID = @"skipa.summary";
    static NSString *cellID = @"skipa.cell";

    if (ip.section == 0) {
        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:summaryID];
        if (!c) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:summaryID];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        NSUInteger total = self.allItems.count;
        unsigned long long bytes = SKIPATotalSize(self.allItems);
        NSUInteger enc = 0, broken = 0, ready = 0;
        for (SKIPA *i in self.allItems) {
            if (!i.analyzed) continue;
            if (i.encrypted) enc++;
            if (i.integrity != SKIPAIntegrityOk) broken++;
            if (!i.encrypted && i.binaries.count && i.integrity == SKIPAIntegrityOk) ready++;
        }
        c.textLabel.text = total ? [NSString stringWithFormat:@"共 %lu 个包 · %@", (unsigned long)total, ADXBytesText(bytes)]
                                 : @"未发现 IPA";
        c.textLabel.font = SKMono(14, UIFontWeightSemibold);
        NSString *detail = total ? [NSString stringWithFormat:@"可直接安装 %lu · 未解密 %lu · 结构异常 %lu",
                                    (unsigned long)ready, (unsigned long)enc, (unsigned long)broken]
                                 : @"文档目录为空";
        c.detailTextLabel.text = detail;
        c.detailTextLabel.font = SKMono(11, UIFontWeightRegular);
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;

        UIButton *filter = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        [filter setImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle" withConfiguration:cfg]
                forState:UIControlStateNormal];
        filter.showsMenuAsPrimaryAction = YES;
        filter.menu = [self filterMenu];
        filter.frame = CGRectMake(0, 0, 40, 40);
        c.accessoryView = filter;
        return c;
    }

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
    }
    SKIPA *ipa = self.items[ip.row];
    cell.textLabel.text = ipa.appName.length ? ipa.appName : ipa.fileName;
    cell.textLabel.font = SKMono(15, UIFontWeightSemibold);
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    NSMutableArray<NSString *> *bits = [NSMutableArray array];
    [bits addObject:ADXBytesText(ipa.fileSize)];
    if (ipa.version.length) [bits addObject:[NSString stringWithFormat:@"v%@", ipa.version]];
    if (ipa.analyzed && ipa.variant.length) [bits addObject:ipa.variant];
    else if (!ipa.analyzed) [bits addObject:@"分析中…"];
    cell.detailTextLabel.text = [bits componentsJoinedByString:@"  ·  "];
    cell.detailTextLabel.font = SKMono(11, UIFontWeightRegular);

    UIColor *tint = UIColor.secondaryLabelColor;
    if (ipa.analyzed) {
        if (ipa.integrity == SKIPAIntegrityUnknown || ipa.integrity == SKIPAIntegrityBroken) tint = UIColor.systemOrangeColor;
        else if (ipa.encrypted) tint = UIColor.systemRedColor;
        else tint = UIColor.systemGreenColor;
    }
    cell.detailTextLabel.textColor = tint;
    cell.imageView.image = [self iconFor:ipa];
    return cell;
}

- (UIImage *)iconFor:(SKIPA *)ipa {
    if (ipa.icon) return ipa.icon;
    NSString *name = ipa.analyzed ? (ipa.integrity != SKIPAIntegrityOk ? @"exclamationmark.triangle.fill" : @"shippingbox.fill")
                                  : @"shippingbox";
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:name withConfiguration:cfg];
}

- (UIMenu *)filterMenu {
    NSArray<NSString *> *titles = @[ @"全部", @"可直接安装（已解密）", @"未解密", @"结构异常" ];
    NSMutableArray<UIAction *> *acts = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSUInteger idx = i;
        UIAction *a = [UIAction actionWithTitle:titles[i] image:nil identifier:nil
                                         handler:^(UIAction *act) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.filter = (NSInteger)idx;
            [strongSelf applyFilter];
            [strongSelf.tableView reloadData];
        }];
        a.state = (self.filter == (NSInteger)i) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [acts addObject:a];
    }
    return [UIMenu menuWithTitle:@"筛选" children:acts];
}

- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    if (ip.section != 1) return;
    [self showActionsForRow:ip];
}

#pragma mark - 多选

- (void)toggleEditing {
    BOOL entering = !self.isEditing;
    [self setEditing:entering animated:YES];
}

- (void)selectAll {
    if (self.tableView.indexPathsForSelectedRows.count >= self.items.count) {
        for (NSIndexPath *p in self.tableView.indexPathsForSelectedRows) {
            [self.tableView deselectRowAtIndexPath:p animated:YES];
        }
        self.navigationItem.leftBarButtonItem.title = @"全选";
        [self updateDeleteButton];
        return;
    }
    for (NSUInteger r = 0; r < self.items.count; r++) {
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)r inSection:1]
                                    animated:YES
                              scrollPosition:UITableViewScrollPositionNone];
    }
    self.navigationItem.leftBarButtonItem.title = @"取消全选";
    [self updateDeleteButton];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:editing ? @"完成" : @"选择"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(toggleEditing)];
    if (editing) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全选"
                                                                                 style:UIBarButtonItemStylePlain
                                                                                target:self
                                                                                action:@selector(selectAll)];
        [self updateDeleteButton];
    } else {
        self.navigationItem.leftBarButtonItem = nil;
        self.toolbarItems = nil;
        self.navigationController.toolbarHidden = YES;
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.isEditing ? UITableViewCellEditingStyleNone : UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isEditing) {
        if (indexPath.section == 1) [self updateDeleteButton];
        return;
    }
    if (indexPath.section == 0) {
        if (self.allItems.count) [self toggleEditing];
        return;
    }
    [self pushDetailForIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isEditing && indexPath.section == 1) [self updateDeleteButton];
}

- (void)updateDeleteButton {
    NSUInteger n = self.tableView.indexPathsForSelectedRows.count;
    self.navigationController.toolbarHidden = !self.isEditing;
    UIBarButtonItem *del = [[UIBarButtonItem alloc] initWithTitle:(n ? [NSString stringWithFormat:@"删除 (%lu)", (unsigned long)n]
                                                                      : @"删除")
                                                            style:UIBarButtonItemStyleDone
                                                           target:self
                                                           action:@selector(deleteSelected)];
    del.enabled = n > 0;
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                            target:self
                                                                            action:@selector(shareSelected)];
    share.enabled = n > 0;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                           target:nil
                                                                           action:nil];
    self.toolbarItems = @[ share, flex, del ];
}

#pragma mark - 删除

/// 列表页需要自己处理 didSelect：多选模式下单元格选中不应推详情页
- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && self.isEditing) return nil;
    return indexPath;
}

- (void)deleteRows:(NSArray<SKIPA *> *)victims {
    NSArray<NSString *> *errors = SKIPADelete(victims);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (SKIPA *ipa in victims) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:ipa.path]) {
                [self.allItems removeObjectIdenticalTo:ipa];
            }
        }
        [self applyFilter];
        [self.tableView reloadData];
        [self updateDeleteButton];
        if (errors.count) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"部分文件没删掉"
                                                                      message:[errors componentsJoinedByString:@"\n"]
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }
    });
}

- (void)deleteSelected {
    NSArray<NSIndexPath *> *sel = self.tableView.indexPathsForSelectedRows;
    if (!sel.count) return;
    NSMutableArray<SKIPA *> *victims = [NSMutableArray array];
    for (NSIndexPath *p in sel) if (p.section == 1) [victims addObject:self.items[p.row]];

    unsigned long long bytes = SKIPATotalSize(victims);
    UIAlertController *a = [UIAlertController
                            alertControllerWithTitle:[NSString stringWithFormat:@"删除 %lu 个 IPA？", (unsigned long)victims.count]
                                             message:[NSString stringWithFormat:@"共 %@，删除后无法恢复。", ADXBytesText(bytes)]
                                      preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf deleteRows:victims];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.toolbarItems.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 1) return nil;
    SKIPA *ipa = self.items[ip.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"删除"
                                                                    handler:^(UIContextualAction *act, UIView *src, void (^done)(BOOL)) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { done(NO); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除这个 IPA？"
                                                                  message:[NSString stringWithFormat:@"%@（%@）",
                                                                           ipa.fileName, ADXBytesText(ipa.fileSize)]
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [strongSelf deleteRows:@[ ipa ]];
            done(YES);
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
        [strongSelf presentViewController:a animated:YES completion:nil];
    }];
    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                       title:@"分享"
                                                                     handler:^(UIContextualAction *act, UIView *src, void (^done)(BOOL)) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf shareItems:@[ ipa ] fromIndexPath:ip];
        done(YES);
    }];
    share.backgroundColor = UIColor.systemBlueColor;
    UIContextualAction *info = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                      title:@"分析"
                                                                    handler:^(UIContextualAction *act, UIView *src, void (^done)(BOOL)) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf pushDetailForIndexPath:ip];
        done(YES);
    }];
    info.backgroundColor = UIColor.systemGrayColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[ del, share, info ]];
}

- (void)pushDetailForIndexPath:(NSIndexPath *)ip {
    if (ip.section != 1) return;
    SKIPADetailViewController *vc = [[SKIPADetailViewController alloc] initWithIPA:self.items[ip.row]];
    __weak typeof(self) weakSelf = self;
    vc.onDeleted = ^(SKIPA *deleted) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.allItems removeObjectIdenticalTo:deleted];
        [strongSelf applyFilter];
        [strongSelf.tableView reloadData];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showActionsForRow:(NSIndexPath *)ip {
    SKIPA *ipa = self.items[ip.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ipa.fileName
                                                                  message:ADXBytesText(ipa.fileSize)
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"分析 / 详情" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf pushDetailForIndexPath:ip];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf shareItems:@[ ipa ] fromIndexPath:ip];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf promptRename:ipa];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf deleteRows:@[ ipa ]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptRename:(SKIPA *)ipa {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"重命名" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = ipa.fileName.stringByDeletingPathExtension;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *e = nil;
        if (!SKIPARename(ipa, a.textFields.firstObject.text ?: @"", &e)) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"重命名失败"
                                                                         message:e.localizedDescription
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:err animated:YES completion:nil];
        }
        [strongSelf.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)shareSelected {
    NSArray<NSIndexPath *> *sel = self.tableView.indexPathsForSelectedRows;
    NSMutableArray<SKIPA *> *items = [NSMutableArray array];
    for (NSIndexPath *p in sel) if (p.section == 1) [items addObject:self.items[p.row]];
    if (items.count) [self shareItems:items fromIndexPath:nil];
}

- (void)shareItems:(NSArray<SKIPA *> *)items fromIndexPath:(nullable NSIndexPath *)ip {
    if (!items.count) return;
    NSMutableArray *acts = [NSMutableArray array];
    for (SKIPA *ipa in items) [acts addObject:[NSURL fileURLWithPath:ipa.path]];
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:acts applicationActivities:nil];
    if (ip) {
        vc.popoverPresentationController.sourceView = self.tableView;
        vc.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:ip];
    } else {
        vc.popoverPresentationController.barButtonItem = self.toolbarItems.firstObject;
    }
    [self presentViewController:vc animated:YES completion:nil];
}

@end
