//
//  SKIPAFilesViewController.m
//  AppDump — 包内文件浏览
//
//  目录来自中央目录（不解压），点文件时才把单个条目解出来：文本 / plist 直接预览，
//  二进制（Mach-O、图片）显示文件头摘要。
//
#import "SKIPAFilesViewController.h"
#import "SKIPAManager.h"
#import "ADXInternal.h"
#import "SKLoc.h"

@interface SKIPAFilesViewController ()
@property (nonatomic, strong) SKIPA *ipa;
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *entries;
@end

@implementation SKIPAFilesViewController

- (instancetype)initWithIPA:(SKIPA *)ipa prefix:(NSString *)prefix {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _ipa = ipa;
        _prefix = [prefix copy] ?: @"";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.prefix.lastPathComponent.length ? self.prefix.lastPathComponent
                                                      : self.ipa.fileName;
    self.tableView.tableFooterView = [UIView new];
    [self loadEntries];
}

- (void)loadEntries {
    SKIPA *ipa = self.ipa;
    NSString *prefix = self.prefix;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *list = SKIPAListEntries(ipa, prefix, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.entries = list;
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"skipa.file";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    NSDictionary *row = self.entries[ip.row];
    BOOL isDir = [row[@"dir"] boolValue];
    NSString *name = row[@"name"];
    c.textLabel.text = name;
    c.textLabel.font = SKMono(13, UIFontWeightRegular);
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15];
    c.imageView.image = [UIImage systemImageNamed:(isDir ? @"folder.fill" : @"doc")
                                withConfiguration:cfg];
    c.imageView.tintColor = isDir ? tv.tintColor : UIColor.secondaryLabelColor;
    if (isDir) {
        NSUInteger n = [row[@"count"] unsignedIntegerValue];
        c.detailTextLabel.text = nil;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        (void)n;
    } else {
        c.accessoryType = UITableViewCellAccessoryNone;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *row = self.entries[ip.row];
    NSString *name = row[@"name"];
    NSString *full = self.prefix.length ? [self.prefix stringByAppendingPathComponent:name] : name;

    if ([row[@"dir"] boolValue]) {
        SKIPAFilesViewController *vc = [[SKIPAFilesViewController alloc] initWithIPA:self.ipa prefix:full];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    [self previewEntry:full];
}

- (void)previewEntry:(NSString *)entry {
    SKIPA *ipa = self.ipa;
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    sp.hidesWhenStopped = YES;
    sp.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 3);
    [self.view addSubview:sp];
    [sp startAnimating];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = SKIPAReadEntry(ipa, entry, 1u << 20);
        NSString *text = nil;
        if (data.length) {
            NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (utf8.length) {
                text = utf8;
            } else {
                NSDictionary *pl = nil;
                @try {
                    pl = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
                } @catch (NSException *e) { pl = nil; }
                if (pl) text = [pl description];
            }
            if (!text) {
                const uint8_t *b = data.bytes;
                unsigned count = (unsigned)MIN(data.length, (NSUInteger)256);
                NSMutableString *hex = [NSMutableString stringWithFormat:@"二进制，共 %@（前 %u 字节）\n\n", ADXBytesText(data.length), count];
                for (unsigned i = 0; i < count; i += 16) {
                    [hex appendFormat:@"%08x  ", i];
                    for (unsigned j = 0; j < 16 && i + j < count; j++) [hex appendFormat:@"%02x ", b[i + j]];
                    [hex appendString:@"\n"];
                }
                text = hex;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [sp stopAnimating];
            [sp removeFromSuperview];

            UIViewController *vc = [UIViewController new];
            vc.view.backgroundColor = UIColor.systemBackgroundColor;
            vc.title = entry.lastPathComponent;
            UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
            tv.font = SKMono(10, UIFontWeightRegular);
            tv.editable = NO;
            tv.text = text.length ? text : @"读不到这个条目（可能是不支持的压缩方式）";
            tv.translatesAutoresizingMaskIntoConstraints = NO;
            [vc.view addSubview:tv];
            [NSLayoutConstraint activateConstraints:@[
                [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
                [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
                [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
                [tv.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
            ]];
            [strongSelf.navigationController pushViewController:vc animated:YES];
        });
    });
}

@end
