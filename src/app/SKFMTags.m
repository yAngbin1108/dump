//
//  SKFMTags.m
//  Blade
//

#import "SKLoc.h"
#import "SKFMTags.h"
#import "FileManager.h"

static NSString * const kTagsKey = @"blade.fm.tags";

@implementation SKFMTags

+ (NSArray<NSDictionary *> *)all {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:kTagsKey];
    if (![a isKindOfClass:NSArray.class]) return @[];

    NSMutableArray *out = [NSMutableArray array];
    for (id o in a) {
        if ([o isKindOfClass:NSDictionary.class] && o[@"name"] && o[@"path"]) [out addObject:o];
    }
    return out;
}

+ (void)write:(NSArray *)list {
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:kTagsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)addName:(NSString *)name path:(NSString *)path {
    if (!name.length || !path.length) return;
    NSMutableArray *list = [[self all] mutableCopy];
    // 同一个路径只留一个，名字取新的
    NSMutableArray *kept = [NSMutableArray array];
    for (NSDictionary *d in list) {
        if (![d[@"path"] isEqualToString:path]) [kept addObject:d];
    }
    [kept insertObject:@{@"name": name, @"path": path} atIndex:0];
    [self write:kept];
}

+ (void)removeAtIndex:(NSInteger)index {
    NSMutableArray *list = [[self all] mutableCopy];
    if (index < 0 || index >= (NSInteger)list.count) return;
    [list removeObjectAtIndex:index];
    [self write:list];
}

+ (BOOL)hasPath:(NSString *)path {
    for (NSDictionary *d in [self all]) {
        if ([d[@"path"] isEqualToString:path]) return YES;
    }
    return NO;
}

@end


@interface SKFMTagsViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *tags;
@end

@implementation SKFMTagsViewController

- (instancetype)initWithCurrentPath:(NSString *)path {
    self = [super init];
    if (self) _currentPath = [path copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SKLoc(@"fm.tags.title");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(addTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    [self reload];
}

- (void)reload {
    self.tags = [SKFMTags all];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : (NSInteger)self.tags.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? SKLoc(@"fm.tags.saveSection") : SKLoc(@"fm.tags.savedSection");
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0 && self.currentPath.length)
        return [NSString stringWithFormat:SKLoc(@"fm.tags.current"), self.currentPath];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"tag";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];

    if (ip.section == 0) {
        c.textLabel.text = SKLoc(@"fm.tags.saveAction");
        c.textLabel.textColor = self.view.tintColor;
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
        c.detailTextLabel.text = nil;
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }

    NSDictionary *d = self.tags[ip.row];
    c.textLabel.text = d[@"name"];
    c.textLabel.textColor = UIColor.labelColor;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    c.detailTextLabel.text = d[@"path"];
    c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) { [self addTapped]; return; }

    NSString *path = self.tags[ip.row][@"path"];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        [self alert:SKLoc(@"fm.tags.missing") msg:path];
        return;
    }
    // 目录就进目录；是个文件就退到它所在的那一层
    NSString *target = isDir ? path : path.stringByDeletingLastPathComponent;
    FileManagerViewController *vc = [[FileManagerViewController alloc] initWithPath:target];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)addTapped {
    if (!self.currentPath.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:SKLoc(@"fm.tags.saveAction")
                                                              message:self.currentPath
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = SKLoc(@"fm.tags.name");
        tf.text = self.currentPath.lastPathComponent.length ? self.currentPath.lastPathComponent
                                                           : self.currentPath;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.save") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *name = a.textFields.firstObject.text;
        name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length) return;
        [SKFMTags addName:name path:self.currentPath];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
                                            forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.section != 1) return;
    [SKFMTags removeAtIndex:ip.row];
    [self reload];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:SKLoc(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
