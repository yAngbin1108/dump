//
//  SKFMPlistEditor.m
//  Blade
//

#import "SKLoc.h"
#import "SKFMPlistEditor.h"
#import "SKSandboxKeeper.h"
#import "SKFileWriter.h"
#import "apfs.h"
#include <sys/stat.h>
#import "darksword.h"
#import "SKPathPolicy.h"
#import "darksword.h"

#include <string.h>

#pragma mark - 编辑上下文

// 顶层 VC 建这个，往下钻的每一层共用它，所以任何一层改了值，
// 保存时写出去的都是同一棵（可变的）树。
@interface SKPlistContext : NSObject
@property (nonatomic, strong) id root;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic)         NSPropertyListFormat format;
@property (nonatomic)         BOOL dirty;
@end
@implementation SKPlistContext
@end


@interface SKFMPlistEditorViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) SKPlistContext *ctx;
@property (nonatomic, strong) id container;         // 本层显示的字典或数组
@property (nonatomic, copy)   NSString *containerTitle;
@property (nonatomic, copy)   NSString *parentKey;  // 本层挂在父层的哪个键/下标下
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *keys; // 字典：排序后的键；数组：@[@0,@1,...]
@end

@implementation SKFMPlistEditorViewController

#pragma mark - 入口

+ (BOOL)looksLikePlist:(NSString *)path {
    if (!path.length) return NO;
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"plist"]) return YES;

    // 没有 .plist 后缀也认：看开头是不是 "bplist" 或 XML
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:16];
    [fh closeFile];
    if (head.length >= 6 && memcmp(head.bytes, "bplist", 6) == 0) return YES;
    if (head.length >= 5 && memcmp(head.bytes, "<?xml", 5) == 0) {
        // <?xml 也可能是普通 XML；只有能解析成 plist 才认
        NSData *all = [NSData dataWithContentsOfFile:path];
        if (all) {
            id o = [NSPropertyListSerialization propertyListWithData:all
                                                            options:0
                                                             format:NULL
                                                              error:NULL];
            return o != nil;
        }
    }
    return NO;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;

    NSPropertyListFormat fmt = NSPropertyListXMLFormat_v1_0;
    NSError *err = nil;
    id root = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListMutableContainersAndLeaves
                                                        format:&fmt
                                                         error:&err];
    if (!root) return nil;

    SKPlistContext *c = [SKPlistContext new];
    c.root = root;
    c.path = [path copy];
    c.format = fmt;
    _ctx = c;
    _container = root;
    _containerTitle = path.lastPathComponent;
    return self;
}

// 钻到下一层用的初始化
- (instancetype)initWithContext:(SKPlistContext *)ctx
                      container:(id)container
                          title:(NSString *)title
                      parentKey:(NSString *)parentKey {
    self = [super init];
    if (self) {
        _ctx = ctx;
        _container = container;
        _containerTitle = [title copy];
        _parentKey = [parentKey copy];
    }
    return self;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.containerTitle ?: @"plist";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                 style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    // 导航栏：
    //   顶层   左=系统返回  右=[新增, 保存]
    //   嵌套层 左=系统返回  右=新增
    // 新增键以前放在 LEFT，那会把系统返回键顶掉（同一个坑在内存编辑器里踩过），
    // 钻进去就退不回来了。所有层级都不要碰 leftBarButtonItem。
    UIBarButtonItem *add =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addTapped)];
    if (!self.parentKey) {
        UIBarButtonItem *save =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                          target:self
                                                          action:@selector(saveTapped)];
        self.navigationItem.rightBarButtonItems = @[ add, save ];
    } else {
        self.navigationItem.rightBarButtonItem = add;
    }

    [self rebuildKeys];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从子层返回时，值可能已经改了，重排一次
    [self rebuildKeys];
    [self.tableView reloadData];
}

- (void)rebuildKeys {
    self.keys = [NSMutableArray array];
    if ([self.container isKindOfClass:NSDictionary.class]) {
        NSArray *sorted = [[(NSDictionary *)self.container allKeys]
                           sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] caseInsensitiveCompare:[b description]];
        }];
        [self.keys addObjectsFromArray:sorted];
    } else if ([self.container isKindOfClass:NSArray.class]) {
        for (NSUInteger i = 0; i < [(NSArray *)self.container count]; i++)
            [self.keys addObject:@(i)];
    }
}

- (id)valueForKey:(id)key {
    if ([self.container isKindOfClass:NSDictionary.class]) return self.container[key];
    if ([self.container isKindOfClass:NSArray.class]) {
        NSUInteger i = [key unsignedIntegerValue];
        return (i < [(NSArray *)self.container count]) ? self.container[i] : nil;
    }
    return nil;
}

- (void)setValue:(id)v forKey:(id)key {
    if ([self.container isKindOfClass:NSMutableDictionary.class]) {
        self.container[key] = v;
    } else if ([self.container isKindOfClass:NSMutableArray.class]) {
        NSUInteger i = [key unsignedIntegerValue];
        if (i < [(NSMutableArray *)self.container count]) self.container[i] = v;
    }
    self.ctx.dirty = YES;
}

#pragma mark - 类型描述

static BOOL FMIsBool(id v) {
    return CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID();
}

static NSString *FMTypeName(id v) {
    if ([v isKindOfClass:NSMutableDictionary.class] || [v isKindOfClass:NSDictionary.class]) return SKLoc(@"fm.plist.dict");
    if ([v isKindOfClass:NSMutableArray.class] || [v isKindOfClass:NSArray.class]) return SKLoc(@"fm.plist.array");
    if (FMIsBool(v)) return SKLoc(@"fm.plist.bool");
    if ([v isKindOfClass:NSNumber.class]) return SKLoc(@"fm.plist.number");
    if ([v isKindOfClass:NSDate.class]) return SKLoc(@"fm.plist.date");
    if ([v isKindOfClass:NSData.class]) return SKLoc(@"fm.plist.data");
    return SKLoc(@"fm.plist.string");
}

static NSString *FMValuePreview(id v) {
    if ([v isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:SKLoc(@"fm.plist.items"), (unsigned long)[v count]];
    if ([v isKindOfClass:NSArray.class]) return [NSString stringWithFormat:SKLoc(@"fm.plist.items"), (unsigned long)[v count]];
    if (FMIsBool(v)) return [v boolValue] ? @"YES" : @"NO";
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    if ([v isKindOfClass:NSDate.class]) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        return [f stringFromDate:v];
    }
    if ([v isKindOfClass:NSData.class]) return [NSString stringWithFormat:SKLoc(@"fm.plist.bytes"), (unsigned long)[v length]];
    NSString *s = [v description] ?: @"";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return s.length > 60 ? [[s substringToIndex:60] stringByAppendingString:@"…"] : s;
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.keys.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if ([self.container isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:SKLoc(@"fm.plist.dictHeader"), (unsigned long)self.keys.count];
    if ([self.container isKindOfClass:NSArray.class]) return [NSString stringWithFormat:SKLoc(@"fm.plist.arrayHeader"), (unsigned long)self.keys.count];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"plist";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];

    id key = self.keys[ip.row];
    id v = [self valueForKey:key];
    c.textLabel.text = [key description];
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", FMTypeName(v), FMValuePreview(v)];
    c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    BOOL container = [v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class];
    c.accessoryType = container ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    id key = self.keys[ip.row];
    id v = [self valueForKey:key];
    if (!v) return;

    if ([v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class]) {
        SKFMPlistEditorViewController *next =
            [[SKFMPlistEditorViewController alloc] initWithContext:self.ctx
                                                         container:v
                                                             title:[key description]
                                                         parentKey:[key description]];
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    [self editValue:v forKey:key];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
                                            forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    id key = self.keys[ip.row];
    if ([self.container isKindOfClass:NSMutableDictionary.class]) {
        [self.container removeObjectForKey:key];
    } else if ([self.container isKindOfClass:NSMutableArray.class]) {
        [self.container removeObjectAtIndex:[key unsignedIntegerValue]];
    }
    self.ctx.dirty = YES;
    [self rebuildKeys];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    [tv reloadData];
}

#pragma mark - 编辑值

- (void)editValue:(id)v forKey:(id)key {
    NSString *title = [NSString stringWithFormat:@"%@ (%@)", [key description], FMTypeName(v)];

    if (FMIsBool(v)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"YES" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self setValue:@YES forKey:key]; [self.tableView reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"NO" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self setValue:@NO forKey:key]; [self.tableView reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.view;
        a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                               CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    if ([v isKindOfClass:NSDate.class]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:@"\n\n\n\n\n\n\n\n"
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
        UIDatePicker *dp = [[UIDatePicker alloc] init];
        dp.datePickerMode = UIDatePickerModeDateAndTime;
        dp.date = v;
        dp.frame = CGRectMake(0, 20, 300, 200);
        [a.view addSubview:dp];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.save") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self setValue:dp.date forKey:key]; [self.tableView reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.view;
        a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                               CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    NSString *initial = nil;
    if ([v isKindOfClass:NSData.class]) {
        initial = [v base64EncodedStringWithOptions:0];
        title = [title stringByAppendingString:@"  base64"];
    } else if ([v isKindOfClass:NSNumber.class]) {
        initial = [v stringValue];
    } else {
        initial = [v description];
    }

    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = initial;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.save") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *text = a.textFields.firstObject.text ?: @"";
        id nv = nil;
        if ([v isKindOfClass:NSData.class]) {
            NSData *d = [[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters];
            nv = d ?: [NSData data];
        } else if ([v isKindOfClass:NSNumber.class]) {
            // NSNumber 可能是 int/long/double；按输入里有没有小数点挑
            if ([text rangeOfString:@"."].location != NSNotFound) nv = @([text doubleValue]);
            else nv = @([text longLongValue]);
        } else {
            nv = text;
        }
        [self setValue:nv forKey:key];
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 增删

- (void)addTapped {
    BOOL isArray = [self.container isKindOfClass:NSArray.class];

    if (isArray) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.plist.append") message:SKLoc(@"fm.plist.defaultStr")
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.plist.string") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [(NSMutableArray *)self.container addObject:@""];
            self.ctx.dirty = YES; [self rebuildKeys]; [self.tableView reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.plist.dict") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [(NSMutableArray *)self.container addObject:[NSMutableDictionary dictionary]];
            self.ctx.dirty = YES; [self rebuildKeys]; [self.tableView reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.plist.array") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [(NSMutableArray *)self.container addObject:[NSMutableArray array]];
            self.ctx.dirty = YES; [self rebuildKeys]; [self.tableView reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.view;
        a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                               CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    UIAlertController *a = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.plist.addKey") message:nil
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = SKLoc(@"fm.plist.keyName");
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"fm.plist.create") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *k = a.textFields.firstObject.text;
        if (!k.length) return;
        [(NSMutableDictionary *)self.container setObject:@"" forKey:k];
        self.ctx.dirty = YES; [self rebuildKeys]; [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 保存

- (void)saveTapped {
    // 顶层 VC，ctx.root 是整棵树
    NSError *err = nil;
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:self.ctx.root
                                                            format:self.ctx.format
                                                           options:0
                                                             error:&err];
    if (!out) {
        [self alert:SKLoc(@"fm.plist.serializeFail") msg:err.localizedDescription];
        return;
    }
    // 只读区不允许写（这条以前漏了，可以从 /Applications 下的系统 app 进来改盘）
    if (!SKPathAllowsModify(self.ctx.path)) {
        [self alert:SKLoc(@"fm.readonly") msg:self.ctx.path];
        return;
    }

    // 按原格式写回：二进制 plist 保持二进制，不会变成 XML
    BOOL wrote = [out writeToFile:self.ctx.path atomically:YES];
    if (!wrote) {
        // .app 内部 DAC 拒绝：先用内核直接改 inode 属主（绕开 vnode_authorize），
        // 再普通写一次。这条路能处理变长内容 —— SKFileWriter 的内核映射路径只能覆盖。
        const char *cp = self.ctx.path.fileSystemRepresentation;
        struct stat st;
        if (ds_is_ready() && stat(cp, &st) == 0) {
            chflags(cp, 0);                       // 清不可变位
            apfs_own(cp, 501, 501);
            apfs_mod(cp, (mode_t)((st.st_mode & 07777) | S_IRUSR | S_IWUSR));
            wrote = [out writeToFile:self.ctx.path atomically:YES];
            SKLog(@"[plist] 内核取得写权限后重写 %@: %@", self.ctx.path, wrote ? @"成功" : @"仍失败");
        }
    }
    if (!wrote && [SKFileWriter kernelWriteAvailable]) {
        // .app 内部 DAC 不允许写，但沙盒已放行 —— 用内核路径覆盖。
        // 注意内核路径不能改变文件大小，所以只在长度一致时才兜底。
        NSError *kerr = nil;
        SKWriteMethod m = [SKFileWriter replacePath:self.ctx.path withData:out error:&kerr];
        if (m != SKWriteMethodFailed) {
            wrote = YES;
            SKLog(@"[plist] 保存 %@: %@", self.ctx.path, [SKFileWriter describeMethod:m]);
        }
    }
    if (!wrote) {
        [self alert:SKLoc(@"fm.plist.saveFail") msg:self.ctx.path];
        return;
    }
    // 写盘会把内核里的沙盒逃逸冲掉，立刻补回来。
    if (ds_is_ready()) [SKSandboxKeeper restoreIfLost:@"保存 plist"];
    self.ctx.dirty = NO;
    NSString *fmt = (self.ctx.format == NSPropertyListBinaryFormat_v1_0) ? SKLoc(@"fm.plist.binary") : @"XML";
    [self alert:SKLoc(@"fm.plist.saved") msg:[NSString stringWithFormat:SKLoc(@"fm.plist.savedBody"), fmt, self.ctx.path]];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
