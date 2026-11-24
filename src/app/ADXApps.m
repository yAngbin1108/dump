//
//  ADXApps.m
//  App 扩展层 — 已安装应用扫描
//
#import "ADXApps.h"
#import "ADXInternal.h"

@implementation ADXApp
@end

static NSArray<NSString *> *ADXBundleRoots(void) {
    return @[ @"/var/containers/Bundle/Application",
              @"/Applications",
              @"/System/Applications",
              @"/private/var/staged_system_apps" ];
}

NSArray<ADXApp *> *ADXScanInstalledApps(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<ADXApp *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *selfID = NSBundle.mainBundle.bundleIdentifier;

    NSMutableArray<NSArray *> *bundles = [NSMutableArray array];   // path, info, isSystem

    // 用户 App：<root>/<uuid>/<Name>.app
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:NULL]) {
        NSString *dir = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:uuid];
        for (NSString *bn in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![bn hasSuffix:@".app"]) continue;
            NSString *bp = [dir stringByAppendingPathComponent:bn];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [bp stringByAppendingPathComponent:@"Info.plist"]];
            if (info) [bundles addObject:@[ bp, info, @NO ]];
        }
    }
    // 系统 App：<root>/<Name>.app
    for (NSString *root in ADXBundleRoots()) {
        if ([root isEqualToString:@"/var/containers/Bundle/Application"]) continue;
        for (NSString *bn in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            if (![bn hasSuffix:@".app"]) continue;
            NSString *bp = [root stringByAppendingPathComponent:bn];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [bp stringByAppendingPathComponent:@"Info.plist"]];
            if (info) [bundles addObject:@[ bp, info, @YES ]];
        }
    }

    for (NSArray *item in bundles) {
        NSString *bp = item[0];
        NSDictionary *info = item[1];
        NSString *bid = info[@"CFBundleIdentifier"];
        NSString *exec = info[@"CFBundleExecutable"];
        if (![bid isKindOfClass:NSString.class] || !bid.length) continue;
        if (![exec isKindOfClass:NSString.class] || !exec.length) continue;
        if (selfID && [bid isEqualToString:selfID]) continue;
        if ([seen containsObject:bid]) continue;
        [seen addObject:bid];

        ADXApp *a = [ADXApp new];
        a.bundleID = bid;
        a.bundlePath = bp;
        a.executable = exec;
        NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
        a.name = [name isKindOfClass:NSString.class] && name.length
                     ? name : bp.lastPathComponent.stringByDeletingPathExtension;
        a.isSystem = [item[2] boolValue];
        [out addObject:a];
    }

    [out sortUsingComparator:^NSComparisonResult(ADXApp *x, ADXApp *y) {
        return [x.name caseInsensitiveCompare:y.name];
    }];
    ADXLogf(@"(fairplay) 扫描到 %lu 个应用", (unsigned long)out.count);
    return out;
}