//
//  SKLaraFileBrowser.m
//  AppDump — 文件管理器
//
//  照官方 lara 的 views/fm（SantanderView / DirectoryView / FileSystemHelpers）：
//  分组列表、每行一个 SF Symbol、应用容器显示名字或 bundle id、导航栏搜索、
//  右上角省略号菜单（上传 / 新建文件夹 / 新建文件 / 粘贴 / 排序 / 隐藏文件 /
//  根目录 / 主目录）、每行长按菜单（复制 / 信息 / 分享 / 重命名 / 替换 / chmod /
//  chown / 删除）。
//
//  与官方的一处刻意差别：写入、删除、重命名这些会改磁盘的操作，按目录可写性
//  禁用（UID=0 的目录如 /、/var 在 501 身份下不可写），避免点下去只得到 EACCES。
//

#import "SKLaraFileBrowser.h"
#import "SKFMKit.h"
#import "SKLog.h"
#import "SKPermRepair.h"
#import "SKPathPolicy.h"
#import "SKSandboxKeeper.h"
#import "SKPermsEditor.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma mark - 条目

@interface SKLaraFileItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;      // 真实文件名
@property (nonatomic, copy) NSString *display;   // 显示名（可能是 app 名 / bundle id）
@property (nonatomic, copy) NSString *appUDID;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, assign) BOOL isApp;
@end

@implementation SKLaraFileItem
@end

#pragma mark - 应用显示（lara 的 appnamecache / bundleappname / bundleidforcontainer）

typedef NS_ENUM(NSInteger, SKFMDisplayMode) {
    SKFMDisplayAppName = 0,
    SKFMDisplayBundleID = 1,
    SKFMDisplayUUID = 2,
};

static NSDictionary<NSString *, NSString *> *SKFMAppNameCache(void) {
    static NSDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSString *bundle = @"/private/var/containers/Bundle/Application";
        for (NSString *app in [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundle error:NULL] ?: @[]) {
            NSString *appPath = [bundle stringByAppendingPathComponent:app];
            for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:appPath error:NULL] ?: @[]) {
                if (![entry hasSuffix:@".app"]) continue;
                NSString *info = [[appPath stringByAppendingPathComponent:entry]
                                  stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:info];
                NSString *bid = plist[@"CFBundleIdentifier"];
                if (!bid.length) continue;
                out[bid] = plist[@"CFBundleDisplayName"] ?: plist[@"CFBundleName"]
                                                        ?: plist[@"CFBundleExecutable"] ?: bid;
                break;
            }
        }
        cache = [out copy];
    });
    return cache;
}

static NSString *SKFMBundleAppName(NSString *dir) {
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL] ?: @[]) {
        if (![entry hasSuffix:@".app"]) continue;
        NSString *info = [[dir stringByAppendingPathComponent:entry] stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:info];
        if (!plist) continue;
        return plist[@"CFBundleDisplayName"] ?: plist[@"CFBundleName"] ?: plist[@"CFBundleExecutable"];
    }
    return nil;
}

static NSString *SKFMBundleIDForContainer(NSString *dir) {
    NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
    return plist[@"MCMMetadataIdentifier"];
}

#pragma mark - 浏览器

@interface SKLaraFileBrowser () <UITableViewDataSource, UITableViewDelegate,
                                 UISearchResultsUpdating, UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) NSArray<SKLaraFileItem *> *items;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSString *emptyMessage;
@property (nonatomic, assign) BOOL sortDescending;
@property (nonatomic, assign) BOOL showHidden;
@property (nonatomic, assign) BOOL writable;
@property (nonatomic, assign) BOOL writabilityKnown;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, strong) UIBarButtonItem *menuButton;

- (void)load;
- (UIMenu *)buildMenu;
- (void)uploadFile;
- (void)newFolder;
- (void)newFile;
- (void)pasteReplacing:(BOOL)replace;
- (void)renameItem:(SKLaraFileItem *)it;
- (void)shareItem:(SKLaraFileItem *)it;
- (void)deleteItem:(SKLaraFileItem *)it;
- (void)showInfo:(SKLaraFileItem *)it;
- (void)chmodItem:(SKLaraFileItem *)it;
- (void)chownItem:(SKLaraFileItem *)it;
- (void)replaceWithClipboard:(SKLaraFileItem *)it;
- (void)repairWriteAccess;
@end

@implementation SKLaraFileBrowser

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        _showHidden = YES;   // 与 lara 的默认一致
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self.path isEqualToString:@"/"] ? @"/" : self.path.lastPathComponent;

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 56;
    self.table.refreshControl = [[UIRefreshControl alloc] init];
    [self.table.refreshControl addTarget:self action:@selector(load)
                        forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.table];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // 搜索框的键盘没有系统的关闭办法（搜索栏挂在导航栏上，没有可点的遮罩），
    // 所以点列表空白处收键盘；cancelsTouchesInView = NO 保证点击照常生效。
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(dismissKeyboard:)];
    tap.cancelsTouchesInView = NO;
    [self.table addGestureRecognizer:tap];
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    self.menuButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                        menu:[self buildMenu]];
    self.navigationItem.rightBarButtonItems = @[ self.menuButton ];

    [self load];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshWritability];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
    CGFloat bottom = self.view.safeAreaInsets.bottom;
    self.table.contentInset = UIEdgeInsetsMake(0, 0, bottom + 5, 0);
    self.table.scrollIndicatorInsets = UIEdgeInsetsMake(0, 0, bottom + 5, 0);
}

- (void)refreshWritability {
    // 能直接写就用；不能写但位于 /var 子树（可内核修权限）也算可操作，
    // 具体操作失败时会先修权限再重试。系统目录保持只读。
    BOOL w = SKFMWritable(self.path) || SKPathAllowsModify(self.path);
    // 第一次必须跑：/ 这类目录初始 writable 就是 NO，早退会让锁图标和菜单状态
    // 永远停在 viewDidLoad 时的样子。
    if (w == self.writable && self.writabilityKnown) {
        self.menuButton.menu = [self buildMenu];
        return;
    }
    self.writable = w;
    self.writabilityKnown = YES;
    if (self.writable) {
        self.navigationItem.rightBarButtonItems = @[ self.menuButton ];
    } else {
        // 只读目录挂一把锁，点一下说明为什么写不了（UID=0 的目录写不了）。
        UIBarButtonItem *lock = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(explainReadOnly)];
        lock.tintColor = UIColor.systemGrayColor;
        self.navigationItem.rightBarButtonItems = @[ self.menuButton, lock ];
    }
    self.menuButton.menu = [self buildMenu];
    [self.table reloadData];
}

- (void)explainReadOnly {
    [self presentViewController:SKFMAlert(@"只读目录",
                                          @"这个目录不属于当前用户（UID 501），无法写入、删除或重命名。\n"
                                          @"需要改这里的文件，请用长按菜单里的 Chmod / Chown。")
                       animated:YES completion:nil];
}

#pragma mark - 加载

- (SKFMDisplayMode)displayMode {
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:@"ad.fmdisplay"];
    if (v == 1) return SKFMDisplayBundleID;
    if (v == 2) return SKFMDisplayUUID;
    return SKFMDisplayAppName;
}

- (BOOL)recursiveSearch {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"ad.fmrecursive"];
}

- (void)load {
    // blade 的算法：每次列目录先确认沙箱逃逸还在（丢了立刻补），再按需把
    // 目标 .app 整树 chown 成 mobile —— 目录的写权限才是关键。
    if (ds_is_ready()) {
        [SKSandboxKeeper restoreIfLost:@"目录刷新"];
        SKPermissionRepairForDirectory(self.path);
    }
    [self refreshWritability];
    self.loading = YES;
    NSString *dir = self.path;
    NSInteger mode = [self displayMode];
    BOOL hidden = self.showHidden;
    NSString *query = [self.query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    BOOL recursive = self.recursiveSearch && query.length > 0;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<SKLaraFileItem *> *list = [NSMutableArray array];
        NSString *empty = nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *err = nil;

        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:&err];
        if (!names) {
            empty = err.code == NSFileReadNoPermissionError
                  ? @"无法列出目录（权限不足）。"
                  : [NSString stringWithFormat:@"无法列出目录：%@", err.localizedDescription ?: @"未知错误"];
            names = @[];
        }

        BOOL isBundleRoot = [dir isEqualToString:@"/private/var/containers/Bundle/Application"]
                         || [dir isEqualToString:@"/var/containers/Bundle/Application"];
        for (NSString *name in names) {
            SKLaraFileItem *it = [SKLaraFileItem new];
            it.name = name;
            it.display = name;
            it.path = [dir isEqualToString:@"/"] ? [@"/" stringByAppendingString:name]
                                                 : [dir stringByAppendingPathComponent:name];
            struct stat st;
            if (stat(it.path.fileSystemRepresentation, &st) != 0) {
                if (lstat(it.path.fileSystemRepresentation, &st) != 0) continue;
            }
            it.isDir = S_ISDIR(st.st_mode);

            if (mode != SKFMDisplayUUID && it.isDir) {
                if (isBundleRoot && mode == SKFMDisplayAppName) {
                    NSString *appName = SKFMBundleAppName(it.path);
                    if (appName.length) { it.display = appName; it.isApp = YES; it.appUDID = name; }
                } else {
                    NSString *bid = SKFMBundleIDForContainer(it.path);
                    if (bid.length) {
                        if (mode == SKFMDisplayAppName) {
                            it.display = SKFMAppNameCache()[bid] ?: bid;
                            it.isApp = YES;
                            it.appUDID = name;
                        } else {
                            it.display = bid;
                        }
                    }
                }
            }
            [list addObject:it];
        }

        if (recursive) {
            // 递归搜索：只按名字/路径匹配，最多 2000 条，命中即停。
            [list removeAllObjects];
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
            NSInteger n = 0;
            for (NSString *rel in en) {
                if (++n > 20000 || list.count >= 2000) break;
                if (!hidden && rel.lastPathComponent.length && [rel.lastPathComponent hasPrefix:@"."]) continue;
                if (![rel localizedCaseInsensitiveContainsString:query]) continue;
                SKLaraFileItem *it = [SKLaraFileItem new];
                it.name = rel.lastPathComponent;
                it.display = rel;
                it.path = [dir isEqualToString:@"/"] ? [@"/" stringByAppendingString:rel]
                                                     : [dir stringByAppendingPathComponent:rel];
                struct stat st;
                if (stat(it.path.fileSystemRepresentation, &st) != 0) continue;
                it.isDir = S_ISDIR(st.st_mode);
                [list addObject:it];
                if (list.count >= 2000) break;
            }
            empty = list.count ? nil : @"没有匹配的项目。";
        } else {
            if (query.length) {
                NSMutableArray *filtered = [NSMutableArray array];
                for (SKLaraFileItem *it in list) {
                    if ([it.display localizedCaseInsensitiveContainsString:query] ||
                        [it.path localizedCaseInsensitiveContainsString:query]) {
                        [filtered addObject:it];
                    }
                }
                list = filtered;
                empty = list.count ? nil : @"没有匹配的项目。";
            }
            if (!hidden) {
                NSMutableArray *filtered = [NSMutableArray array];
                for (SKLaraFileItem *it in list) {
                    if (![it.name hasPrefix:@"."]) [filtered addObject:it];
                }
                list = filtered;
                if (!list.count && !empty.length && names.count) empty = @"没有可见项目（开启隐藏文件后可显示）。";
            }
            if (!empty.length && !list.count) empty = @"目录是空的。";
        }

        [list sortUsingComparator:^NSComparisonResult(SKLaraFileItem *a, SKLaraFileItem *b) {
            if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
            return [a.display localizedCaseInsensitiveCompare:b.display];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            self.items = list;
            self.emptyMessage = empty;
            self.loading = NO;
            [self.table.refreshControl endRefreshing];
            [self.table reloadData];
        });
    });
}


// ─────────────────────────────────────────────────────────────────────────────
// 失败后修一次权限再重试（blade 的做法）
//
// blade 的写/删/改名都是"先普通系统调用，EPERM 再走内核改属主，然后重试一次"。
// 这里保持同样的次序：普通调用 -> 修目标（落盘操作再修父目录）-> 重试一次。
// ─────────────────────────────────────────────────────────────────────────────
static BOOL SKFMRetryWithRepair(BOOL (^op)(NSError **), NSString *target,
                                BOOL repairParent, NSError **err) {
    if (op(err)) return YES;
    NSError *first = err && *err ? *err : nil;      // 第一次的失败原因先留着
    if (repairParent && target.length) SKPermissionRepairParent(target);
    if (target.length) SKPermissionRepair(target);
    if (op(err)) return YES;
    if (err && !*err) *err = first;
    return NO;
}

- (NSArray<SKLaraFileItem *> *)shown {
    if (!self.sortDescending) return self.items ?: @[];
    return [[(self.items ?: @[]) reverseObjectEnumerator] allObjects];
}

- (void)dismissKeyboard:(UIGestureRecognizer *)g {
    if (self.search.searchBar.isFirstResponder || self.search.isActive) {
        [self.search.searchBar resignFirstResponder];
        [self.view endEditing:YES];
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)c {
    NSString *q = c.searchBar.text ?: @"";
    if ([q isEqualToString:self.query ?: @""]) return;
    self.query = q;

    // 每敲一个字都重扫目录太浪费（递归搜索尤其），等 250ms 再真正加载。
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(load) object:nil];
    [self performSelector:@selector(load) withObject:nil afterDelay:0.25];
}

#pragma mark - 列表

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *shown = [self shown];
    return shown.count ?: 1;   // 空目录也要一行提示
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"row";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSArray<SKLaraFileItem *> *shown = [self shown];
    UIListContentConfiguration *cc = [c defaultContentConfiguration];

    if (!shown.count) {
        cc.text = self.loading ? @"载入中…" : (self.emptyMessage ?: @"目录是空的。");
        cc.textProperties.color = UIColor.secondaryLabelColor;
        c.contentConfiguration = cc;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }

    SKLaraFileItem *it = shown[indexPath.row];
    cc.image = [UIImage systemImageNamed:[self iconForItem:it]];
    cc.imageProperties.tintColor = it.isDir ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    cc.text = it.display;
    cc.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if ([it.name hasPrefix:@"."]) cc.textProperties.color = UIColor.systemGrayColor;

    if (it.appUDID.length) {
        cc.secondaryText = it.appUDID;
        cc.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cc.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    } else if (self.query.length) {
        cc.secondaryText = it.path;
        cc.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        cc.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        cc.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    c.contentConfiguration = cc;
    c.accessoryType = it.isDir ? UITableViewCellAccessoryDisclosureIndicator
                               : UITableViewCellAccessoryNone;
    return c;
}

- (NSString *)iconForItem:(SKLaraFileItem *)it {
    if (it.isDir) return @"folder.fill";
    UTType *t = it.path.pathExtension.length ? [UTType typeWithFilenameExtension:it.path.pathExtension] : nil;
    if (!t) return @"doc";
    if ([t conformsToType:UTTypeText]) return @"doc.text";
    if ([t conformsToType:UTTypeImage]) return @"photo";
    if ([t conformsToType:UTTypeAudio]) return @"waveform";
    if ([t conformsToType:UTTypeMovie] || [t conformsToType:UTTypeVideo]) return @"play.rectangle";
    return @"doc";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<SKLaraFileItem *> *shown = [self shown];
    if (!shown.count) return;
    SKLaraFileItem *it = shown[indexPath.row];
    if (it.isDir) {
        [self.navigationController pushViewController:[[SKLaraFileBrowser alloc] initWithPath:it.path]
                                             animated:YES];
    } else {
        [self showInfo:it];
    }
}

#pragma mark - 长按菜单（lara 的 contextMenu）

// 注意选择器：UITableView 的长按菜单是 contextMenuConfigurationForRowAtIndexPath:point:，
// 写成 configurationForRowAtIndexPath: 这个代理方法根本不会被调用，于是长按毫无反应。
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                    point:(CGPoint)point {
    NSArray<SKLaraFileItem *> *shown = [self shown];
    if (!shown.count) return nil;
    SKLaraFileItem *it = shown[indexPath.row];
    BOOL writable = SKFMItemWritable(it.path);
    BOOL hasClip = SKFMClipboard.shared.item != nil;
    BOOL isSelfOrChild = [self clipboardInsideOf:it];

    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *copy = [UIAction actionWithTitle:@"复制"
                                            image:[UIImage systemImageNamed:@"doc.on.doc"]
                                       identifier:nil
                                          handler:^(UIAction *a) { [self copyItem:it]; }];
        UIAction *info = [UIAction actionWithTitle:@"信息"
                                            image:[UIImage systemImageNamed:@"info.circle"]
                                       identifier:nil
                                          handler:^(UIAction *a) { [self showInfo:it]; }];
        UIAction *share = [UIAction actionWithTitle:@"分享"
                                             image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                        identifier:nil
                                           handler:^(UIAction *a) { [self shareItem:it]; }];
        share.attributes = it.isDir ? UIMenuElementAttributesDisabled : 0;

        UIAction *rename = [UIAction actionWithTitle:@"重命名"
                                              image:[UIImage systemImageNamed:@"pencil"]
                                         identifier:nil
                                            handler:^(UIAction *a) { [self renameItem:it]; }];
        rename.attributes = writable ? 0 : UIMenuElementAttributesDisabled;

        UIAction *replace = [UIAction actionWithTitle:@"用剪贴板替换"
                                               image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                          identifier:nil
                                             handler:^(UIAction *a) { [self replaceWithClipboard:it]; }];
        replace.attributes = (hasClip && writable && !isSelfOrChild) ? 0 : UIMenuElementAttributesDisabled;

        UIAction *chmod = [UIAction actionWithTitle:@"Chmod"
                                             image:[UIImage systemImageNamed:@"lock.open"]
                                        identifier:nil
                                           handler:^(UIAction *a) { [self chmodItem:it]; }];
        UIAction *chown = [UIAction actionWithTitle:@"Chown"
                                             image:[UIImage systemImageNamed:@"person.crop.circle"]
                                        identifier:nil
                                           handler:^(UIAction *a) { [self chownItem:it]; }];

        UIAction *del = [UIAction actionWithTitle:@"删除"
                                           image:[UIImage systemImageNamed:@"trash"]
                                      identifier:nil
                                         handler:^(UIAction *a) { [self deleteItem:it]; }];
        del.attributes = (writable ? 0 : UIMenuElementAttributesDisabled) | UIMenuElementAttributesDestructive;

        return [UIMenu menuWithChildren:@[ copy, info, share, rename, replace, chmod, chown, del ]];
    }];
}

- (BOOL)clipboardInsideOf:(SKLaraFileItem *)it {
    SKFMClipItem *clip = SKFMClipboard.shared.item;
    if (!clip) return NO;
    return [it.path isEqualToString:clip.path] || [it.path hasPrefix:[clip.path stringByAppendingString:@"/"]];
}

#pragma mark - 省略号菜单（lara 的 toolbar Menu）

// ── 修复写权限 ──────────────────────────────────────────────────────────────
// 沙盒策略的编辑只活在内存里：任何一次真实的落盘都会让内核重新处理扩展表，
// 我们改进去的那份被换回原样。这个动作把策略重放一次（探针正常时零内核写），
// 顺便把当前目录的属主修成 mobile，然后把结果原样告诉用户。
- (void)repairWriteAccess {
    NSString *dir = self.path;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *report = [SKSandboxKeeper repairWriteAccessReportForPath:dir];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf presentViewController:SKFMAlert(@"修复写权限", report)
                                   animated:YES completion:nil];
            [weakSelf load];
        });
    });
}

- (UIMenu *)buildMenu {
    __weak typeof(self) weakSelf = self;
    BOOL writable = self.writable;
    BOOL hasClip = SKFMClipboard.shared.item != nil;

    UIAction *upload = [UIAction actionWithTitle:@"上传文件"
                                           image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                      identifier:nil
                                         handler:^(UIAction *a) { [weakSelf uploadFile]; }];
    UIAction *folder = [UIAction actionWithTitle:@"新建文件夹"
                                           image:[UIImage systemImageNamed:@"folder.badge.plus"]
                                      identifier:nil
                                         handler:^(UIAction *a) { [weakSelf newFolder]; }];
    UIAction *file = [UIAction actionWithTitle:@"新建文件"
                                         image:[UIImage systemImageNamed:@"doc.badge.plus"]
                                    identifier:nil
                                       handler:^(UIAction *a) { [weakSelf newFile]; }];
    UIAction *paste = [UIAction actionWithTitle:@"粘贴"
                                          image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                     identifier:nil
                                        handler:^(UIAction *a) { [weakSelf pasteReplacing:NO]; }];
    UIAction *pasteReplace = [UIAction actionWithTitle:@"粘贴并替换"
                                                  image:[UIImage systemImageNamed:@"doc.on.clipboard.fill"]
                                             identifier:nil
                                                handler:^(UIAction *a) { [weakSelf pasteReplacing:YES]; }];
    for (UIAction *a in @[ upload, folder, file ]) {
        if (!writable) a.attributes = UIMenuElementAttributesDisabled;
    }
    if (!writable || !hasClip) {
        paste.attributes = UIMenuElementAttributesDisabled;
        pasteReplace.attributes = UIMenuElementAttributesDisabled;
    }

    UIAction *az = [UIAction actionWithTitle:@"A-Z" image:nil identifier:nil handler:^(UIAction *a) {
        weakSelf.sortDescending = NO;
        [weakSelf.table reloadData];
    }];
    UIAction *za = [UIAction actionWithTitle:@"Z-A" image:nil identifier:nil handler:^(UIAction *a) {
        weakSelf.sortDescending = YES;
        [weakSelf.table reloadData];
    }];
    UIMenu *sort = [UIMenu menuWithTitle:@"排序"
                                   image:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                              identifier:nil
                                 options:0
                               children:@[ az, za ]];

    UIAction *hidden = [UIAction actionWithTitle:(self.showHidden ? @"隐藏隐藏文件" : @"显示隐藏文件")
                                          image:[UIImage systemImageNamed:@"eye"]
                                     identifier:nil
                                        handler:^(UIAction *a) {
        weakSelf.showHidden = !weakSelf.showHidden;
        [weakSelf load];
    }];
    UIAction *root = [UIAction actionWithTitle:@"前往根目录"
                                        image:[UIImage systemImageNamed:@"externaldrive"]
                                   identifier:nil
                                      handler:^(UIAction *a) {
        [weakSelf.navigationController pushViewController:[[SKLaraFileBrowser alloc] initWithPath:@"/"]
                                                 animated:YES];
    }];
    // blade 的「修复写权限」：只重放沙盒策略 + 修属主，绝不重跑利用链。
    // 放在这里是因为「写不进去」永远发生在文件管理器里 —— 就地修完继续操作。
    UIAction *repair = [UIAction actionWithTitle:@"修复写权限"
                                            image:[UIImage systemImageNamed:@"lock.open"]
                                       identifier:nil
                                          handler:^(UIAction *a) { [weakSelf repairWriteAccess]; }];

    UIAction *home = [UIAction actionWithTitle:@"前往主目录"
                                        image:[UIImage systemImageNamed:@"house"]
                                   identifier:nil
                                      handler:^(UIAction *a) {
        [weakSelf.navigationController pushViewController:
            [[SKLaraFileBrowser alloc] initWithPath:NSHomeDirectory()] animated:YES];
    }];

    return [UIMenu menuWithChildren:@[ upload, folder, file, paste, pasteReplace, repair,
                                       sort, hidden, root, home ]];
}

#pragma mark - 操作

- (void)copyItem:(SKLaraFileItem *)it {
    SKFMClipItem *c = [SKFMClipItem new];
    c.path = it.path;
    c.name = it.name;
    c.isDir = it.isDir;
    SKFMClipboard.shared.item = c;
    [self presentViewController:SKFMAlert(@"已复制", it.display) animated:YES completion:nil];
}

- (void)uploadFile {
    if (!self.writable) { [self explainReadOnly]; return; }
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;
    NSString *dir = self.path;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSInteger copied = 0;

    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *dest = SKFMUniquePath([dir stringByAppendingPathComponent:url.lastPathComponent]);
        NSError *err = nil;
        if (SKFMCopyItem(url.path, dest, &err)) copied++;
        else [failures addObject:[NSString stringWithFormat:@"%@：%@", url.lastPathComponent,
                                  err.localizedDescription ?: @"复制失败"]];
        if (scoped) [url stopAccessingSecurityScopedResource];
    }

    SKLog(@"[fm] upload: %ld copied into %@", (long)copied, dir);
    [self load];

    if (failures.count) {
        [self presentViewController:SKFMAlert(@"上传失败", [failures componentsJoinedByString:@"\n"])
                           animated:YES completion:nil];
    }
}

- (void)newFolder {
    if (!self.writable) { [self explainReadOnly]; return; }
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"新建文件夹" message:self.path
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"New Folder"; }];
    [al addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *name = [al.textFields.firstObject.text
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length) return;
        if ([name containsString:@"/"]) {
            [self presentViewController:SKFMAlert(@"新建文件夹失败", @"名称不能包含 “/”。")
                               animated:YES completion:nil];
            return;
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:[self.path stringByAppendingPathComponent:name]]) {
            [self presentViewController:SKFMAlert(@"新建文件夹失败", @"同名项目已存在。")
                               animated:YES completion:nil];
            return;
        }
        NSError *err = nil;
        NSString *dest = [self.path stringByAppendingPathComponent:name];
        BOOL made = SKFMRetryWithRepair(^(NSError **e){ return SKFMCreateDirectory(dest, e); }, dest, YES, &err);
        if (!made) {
            [self presentViewController:SKFMAlert(@"新建文件夹失败", err.localizedDescription)
                               animated:YES completion:nil];
            return;
        }
        [self load];
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)newFile {
    if (!self.writable) { [self explainReadOnly]; return; }
    SKFMNewFileViewController *vc = [SKFMNewFileViewController new];
    vc.directory = self.path;
    __weak typeof(self) weakSelf = self;
    vc.onCreated = ^(NSString *path) { [weakSelf load]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)pasteReplacing:(BOOL)replace {
    if (!self.writable) { [self explainReadOnly]; return; }
    SKFMClipItem *clip = SKFMClipboard.shared.item;
    if (!clip) return;

    if (clip.isDir && ([self.path isEqualToString:clip.path] ||
                       [self.path hasPrefix:[clip.path stringByAppendingString:@"/"]])) {
        [self presentViewController:SKFMAlert(@"粘贴失败", @"不能把文件夹粘贴到它自己里面。")
                           animated:YES completion:nil];
        return;
    }

    NSString *base = [self.path stringByAppendingPathComponent:clip.name];
    NSString *dest = replace ? base : SKFMUniquePath(base);
    NSError *err = nil;
    NSFileManager *fm = NSFileManager.defaultManager;

    if (replace && [fm fileExistsAtPath:dest]) {
        if (!SKFMRetryWithRepair(^(NSError **e){ return SKFMRemoveItem(dest, e); }, dest, YES, &err)) {
            [self presentViewController:SKFMAlert(@"粘贴失败", err.localizedDescription)
                               animated:YES completion:nil];
            return;
        }
    }
    if (!SKFMRetryWithRepair(^(NSError **e){ return SKFMCopyItem(clip.path, dest, e); }, dest, YES, &err)) {
        [self presentViewController:SKFMAlert(@"粘贴失败", err.localizedDescription)
                           animated:YES completion:nil];
        return;
    }
    SKLog(@"[fm] paste %@ -> %@", clip.path, dest);
    [self load];
}

- (void)replaceWithClipboard:(SKLaraFileItem *)it {
    SKFMClipItem *clip = SKFMClipboard.shared.item;
    if (!clip) return;
    if ([self clipboardInsideOf:it]) return;

    NSError *err = nil;
    if (!SKFMRetryWithRepair(^(NSError **e){ return SKFMRemoveItem(it.path, e); }, it.path, YES, &err)) {
        [self presentViewController:SKFMAlert(@"替换失败", err.localizedDescription)
                           animated:YES completion:nil];
        return;
    }
    if (!SKFMRetryWithRepair(^(NSError **e){ return SKFMCopyItem(clip.path, it.path, e); }, it.path, YES, &err)) {
        [self presentViewController:SKFMAlert(@"替换失败", err.localizedDescription)
                           animated:YES completion:nil];
        return;
    }
    SKLog(@"[fm] replace %@ with %@", it.path, clip.path);
    [self load];
}

- (void)renameItem:(SKLaraFileItem *)it {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"重命名" message:it.name
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = it.name; }];
    [al addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *name = [al.textFields.firstObject.text
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length || [name isEqualToString:it.name]) return;
        if ([name containsString:@"/"]) {
            [self presentViewController:SKFMAlert(@"重命名失败", @"名称不能包含 “/”。")
                               animated:YES completion:nil];
            return;
        }
        NSString *dst = [self.path stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:dst]) {
            [self presentViewController:SKFMAlert(@"重命名失败", @"同名项目已存在。")
                               animated:YES completion:nil];
            return;
        }
        NSError *err = nil;
        if (!SKFMRetryWithRepair(^(NSError **e){ return SKFMMoveItem(it.path, dst, e); }, dst, YES, &err)) {
            [self presentViewController:SKFMAlert(@"重命名失败", err.localizedDescription)
                               animated:YES completion:nil];
            return;
        }
        [self load];
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)deleteItem:(SKLaraFileItem *)it {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"删除"
                                                               message:[NSString stringWithFormat:@"确定删除 “%@”？", it.display]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        NSError *err = nil;
        if (!SKFMRetryWithRepair(^(NSError **e){ return SKFMRemoveItem(it.path, e); }, it.path, YES, &err)) {
            [self presentViewController:SKFMAlert(@"删除失败", err.localizedDescription)
                               animated:YES completion:nil];
            return;
        }
        SKLog(@"[fm] deleted %@", it.path);
        [self load];
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)showInfo:(SKLaraFileItem *)it {
    SKFMInfoViewController *vc = [[SKFMInfoViewController alloc] initWithPath:it.path];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)chmodItem:(SKLaraFileItem *)it {
    struct stat st;
    if (stat(it.path.fileSystemRepresentation, &st) != 0) {
        [self presentViewController:SKFMAlert(@"Chmod 失败", @"无法读取该项目的属性。")
                           animated:YES completion:nil];
        return;
    }
    SKPermsEditor *vc = [[SKPermsEditor alloc] initWithPath:it.path
                                                     mode:(unsigned)(st.st_mode & 07777)
                                                    isDir:it.isDir];
    __weak typeof(self) weakSelf = self;
    vc.onApplied = ^(unsigned int newMode) { [weakSelf load]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)chownItem:(SKLaraFileItem *)it {
    struct stat st;
    if (stat(it.path.fileSystemRepresentation, &st) != 0) {
        [self presentViewController:SKFMAlert(@"Chown 失败", @"无法读取该项目的属性。")
                           animated:YES completion:nil];
        return;
    }
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Chown"
                                                               message:it.display
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [NSString stringWithFormat:@"%u", st.st_uid];
        tf.placeholder = @"UID";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [NSString stringWithFormat:@"%u", st.st_gid];
        tf.placeholder = @"GID";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [al addAction:[UIAlertAction actionWithTitle:@"应用" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        unsigned int uid = (unsigned int)[al.textFields[0].text intValue];
        unsigned int gid = (unsigned int)[al.textFields[1].text intValue];
        BOOL ok = SKFMChown(it.path, uid, gid);
        if (!ok) {
            [self presentViewController:SKFMAlert(@"Chown 失败", @"操作失败（可能需要先跑利用拿到内核读写）。")
                               animated:YES completion:nil];
        }
        [self load];
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)shareItem:(SKLaraFileItem *)it {
    if (it.isDir) {
        [self presentViewController:SKFMAlert(@"无法分享", @"不支持分享文件夹。") animated:YES completion:nil];
        return;
    }
    if (access(it.path.fileSystemRepresentation, R_OK) != 0) {
        [self presentViewController:SKFMAlert(@"无法分享", @"文件不可读。") animated:YES completion:nil];
        return;
    }
    UIActivityViewController *av =
        [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:it.path] ]
                                          applicationActivities:nil];
    av.popoverPresentationController.sourceView = self.view;
    av.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                             CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:av animated:YES completion:nil];
}

@end
