//
//  SKIPADetailViewController.m
//  AppDump — IPA 详情 / 分析结果
//
//  结构：
//    0 概览（应用名、Bundle ID、版本、最低系统、文件信息）
//    1 分析结论（结构、签名、加密、架构、扩展）—— 每项带颜色状态点
//    2 包内二进制（逐个列架构与 cryptid）
//    3 提示 / 建议
//    4 包内文件（可点进去逐层浏览，不解压整包）
//
#import "SKIPADetailViewController.h"
#import "SKIPAFilesViewController.h"
#import "SKIPAManager.h"
#import "ADXInternal.h"
#import "SKLoc.h"

@interface SKIPADetailViewController ()
@property (nonatomic, strong) SKIPA *ipa;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation SKIPADetailViewController

- (instancetype)initWithIPA:(SKIPA *)ipa {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _ipa = ipa;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.ipa.appName.length ? self.ipa.appName : self.ipa.fileName;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    UIBarButtonItem *shareBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                             target:self
                                                                             action:@selector(share)];
    UIBarButtonItem *delBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                                           target:self
                                                                           action:@selector(deleteIPA)];
    delBtn.tintColor = UIColor.systemRedColor;
    self.navigationItem.rightBarButtonItems = @[ shareBtn, delBtn ];
    [self reanalyzeIfNeeded];
}

- (void)reanalyzeIfNeeded {
    if (self.ipa.analyzed) {
        [self updateTitle];
        return;
    }
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    sp.hidesWhenStopped = YES;
    self.navigationItem.titleView = sp;
    [sp startAnimating];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SKIPAAnalyze(weakSelf.ipa);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [sp stopAnimating];
            strongSelf.navigationItem.titleView = nil;
            [strongSelf updateTitle];
            [strongSelf.tableView reloadData];
        });
    });
}

- (void)updateTitle {
    if (self.ipa.appName.length) self.title = self.ipa.appName;
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return @"概览";
        case 1: return @"分析结论";
        case 2: return self.ipa.binaries.count ? @"包内二进制" : nil;
        case 3: return self.ipa.notes.count ? @"提示" : nil;
        default: return self.ipa.analyzed ? @"包内文件" : nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return self.ipa.path;
    if (s == 2) return @"「cryptid≠0」表示该二进制仍带 LC_ENCRYPTION_INFO 的非零 cryptid，"
                       "这种包安装后会闪退，需要重新砸壳。";
    if (s == 4) return @"只读取包内目录与文件头，不解压整包。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0: return 6;
        case 1: return 6 + (self.ipa.extensionSummary.length ? 1 : 0) + (self.ipa.hasWatchApp ? 1 : 0);
        case 2: return (NSInteger)self.ipa.binaries.count;
        case 3: return (NSInteger)self.ipa.notes.count;
        default: return 1;
    }
}

- (UITableViewCell *)infoCell:(UITableView *)tv title:(NSString *)title value:(NSString *)value {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.text = title;
    c.textLabel.font = SKMono(13, UIFontWeightRegular);
    c.textLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.text = value ?: @"—";
    c.detailTextLabel.font = SKMono(13, UIFontWeightMedium);
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    SKIPA *a = self.ipa;
    switch (ip.section) {
        case 0: {
            NSArray *keys = @[ @"文件", @"大小", @"修改时间", @"Bundle ID", @"版本", @"最低系统" ];
            NSArray *vals = @[ a.fileName, ADXBytesText(a.fileSize),
                               [NSDateFormatter localizedStringFromDate:a.modified
                                                              dateStyle:NSDateFormatterMediumStyle
                                                              timeStyle:NSDateFormatterShortStyle],
                               a.bundleID ?: @"—", a.version ?: @"—",
                               a.minimumOS ?: @"—" ];
            return [self infoCell:tv title:keys[ip.row] value:vals[ip.row]];
        }
        case 1: {
            NSMutableArray *keys = [NSMutableArray arrayWithArray:@[ @"结构完整性", @"签名", @"加密状态", @"架构", @"条目数", @"解压后大小" ]];
            NSMutableArray *vals = [NSMutableArray arrayWithArray:@[
                a.integrity == SKIPAIntegrityOk ? @"完整"
                    : a.integrity == SKIPAIntegrityBroken ? [NSString stringWithFormat:@"异常 — %@", a.problem ?: @"未知"]
                    : @"无法读取",
                a.signed ? @"有 _CodeSignature" : @"缺失",
                a.encrypted ? @"仍有密文（不能直接用）" : (a.binaries.count ? @"已解密" : @"未检测"),
                a.archs.count ? [a.archs componentsJoinedByString:@", "] : @"—",
                a.entryCount ? [NSString stringWithFormat:@"%lu", (unsigned long)a.entryCount] : @"—",
                a.uncompressedTotal ? ADXBytesText(a.uncompressedTotal) : @"—",
            ]];
            if (a.extensionSummary.length) { [keys addObject:@"扩展"]; [vals addObject:a.extensionSummary]; }
            if (a.hasWatchApp) { [keys addObject:@"Watch"]; [vals addObject:@"包含"]; }

            UITableViewCell *c = [self infoCell:tv title:keys[ip.row] value:vals[ip.row]];
            UIColor *color = UIColor.labelColor;
            if (ip.row == 0) color = a.integrity == SKIPAIntegrityOk ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
            else if (ip.row == 1) color = a.signed ? UIColor.labelColor : UIColor.systemOrangeColor;
            else if (ip.row == 2) color = a.encrypted ? UIColor.systemRedColor
                                     : (a.binaries.count ? UIColor.systemGreenColor : UIColor.secondaryLabelColor);
            c.detailTextLabel.textColor = color;
            return c;
        }
        case 2: {
            SKIPABinary *b = a.binaries[ip.row];
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.textLabel.text = b.path.lastPathComponent;
            c.textLabel.font = SKMono(13, UIFontWeightSemibold);
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@  ·  %@",
                                      b.archs.length ? b.archs : @"?",
                                      ADXBytesText(b.size),
                                      b.encrypted ? @"cryptid≠0" : @"明文"];
            c.detailTextLabel.font = SKMono(11, UIFontWeightRegular);
            c.detailTextLabel.textColor = b.encrypted ? UIColor.systemRedColor : UIColor.systemGreenColor;
            c.accessoryType = UITableViewCellAccessoryNone;
            c.indentationLevel = 0;
            return c;
        }
        case 3: {
            UITableViewCell *c = [self infoCell:tv title:nil value:self.ipa.notes[ip.row]];
            c.textLabel.text = nil;
            c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            c.detailTextLabel.font = SKMono(12, UIFontWeightRegular);
            return c;
        }
        default: {
            UITableViewCell *c = [self infoCell:tv title:@"浏览 Payload 目录" value:a.entryCount ? [NSString stringWithFormat:@"%lu 项", (unsigned long)a.entryCount] : nil];
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.textLabel.textColor = tv.tintColor;
            c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            return c;
        }
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0) {
        [self share];
        return;
    }
    if (ip.section == 4) {
        SKIPAFilesViewController *vc = [[SKIPAFilesViewController alloc] initWithIPA:self.ipa prefix:@""];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)share {
    // 分享文件 + 分析报告文本
    NSString *report = SKIPAReportText(self.ipa);
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@.txt", self.ipa.fileName.stringByDeletingPathExtension]];
    [report writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURL fileURLWithPath:self.ipa.path]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:tmp]) [items addObject:[NSURL fileURLWithPath:tmp]];
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    vc.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)deleteIPA {
    SKIPA *ipa = self.ipa;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除这个 IPA？"
                                                              message:[NSString stringWithFormat:@"%@（%@）\n删除后无法恢复。",
                                                                       ipa.fileName, ADXBytesText(ipa.fileSize)]
                                                       preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray<NSString *> *errors = SKIPADelete(@[ ipa ]);
        if (errors.count) {
            UIAlertController *e = [UIAlertController alertControllerWithTitle:@"删除失败"
                                                                       message:[errors componentsJoinedByString:@"\n"]
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [e addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:e animated:YES completion:nil];
            return;
        }
        if (strongSelf.onDeleted) strongSelf.onDeleted(ipa);
        [strongSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
