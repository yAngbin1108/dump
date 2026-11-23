//
//  SKToolApps.m
//  AppDump — 见 SKToolApps.h
//

#import "SKToolApps.h"

#import <unistd.h>

static NSString * const kSKUserBundleRoot = @"/var/containers/Bundle/Application";

@implementation SKToolApp

- (NSString *)groupPath {
    return self.bundlePath.stringByDeletingLastPathComponent;
}

- (NSString *)placeholderPath {
    return [self.groupPath stringByAppendingPathComponent:@"com.apple.mobileinstallation.placeholder"];
}

- (BOOL)blocked {
    NSString *p = self.placeholderPath;
    if (!p) return NO;
    return access(p.UTF8String, F_OK) == 0;
}

@end

UIImage *SKToolLoadIcon(NSString *bundlePath, NSDictionary *info, CGFloat side) {
    if (!bundlePath || !info) return nil;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    id icons = info[@"CFBundleIcons"];
    if ([icons isKindOfClass:[NSDictionary class]]) {
        id primary = icons[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:[NSDictionary class]]) {
            id files = primary[@"CFBundleIconFiles"];
            if ([files isKindOfClass:[NSArray class]] && [files count]) {
                [candidates addObject:[files lastObject]];
            }
        }
    }
    id legacy = info[@"CFBundleIconFiles"];
    if ([legacy isKindOfClass:[NSArray class]] && [legacy count]) {
        [candidates addObject:[legacy lastObject]];
    }
    id iconName = info[@"CFBundleIconName"];
    if ([iconName isKindOfClass:[NSString class]]) [candidates addObject:iconName];
    [candidates addObject:@"AppIcon60x60"];

    UIImage *raw = nil;
    for (NSString *base in candidates) {
        if (![base isKindOfClass:[NSString class]] || base.length == 0) continue;
        for (NSString *suffix in @[ @"@3x.png", @"@2x.png", @".png", @"" ]) {
            NSString *file = [base stringByAppendingString:suffix];
            NSString *path = [bundlePath stringByAppendingPathComponent:file];
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            if (img) { raw = img; break; }
        }
        if (raw) break;
    }
    if (!raw) return nil;

    CGSize size = CGSizeMake(side, side);
    UIGraphicsBeginImageContextWithOptions(size, NO, UIScreen.mainScreen.scale);
    UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                                       cornerRadius:side * 0.22];
    [clip addClip];
    [raw drawInRect:CGRectMake(0, 0, side, side)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

NSArray<SKToolApp *> *SKToolLoadApps(BOOL includeSystem) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *selfID = NSBundle.mainBundle.bundleIdentifier;
    NSMutableArray<NSArray *> *bundles = [NSMutableArray array];   // @[path, info, isSystem]

    // ① 用户 App：/var/containers/Bundle/Application/<uuid>/<Name>.app
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:kSKUserBundleRoot error:NULL]) {
        NSString *dir = [kSKUserBundleRoot stringByAppendingPathComponent:uuid];
        for (NSString *bn in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![bn hasSuffix:@".app"]) continue;
            NSString *bp = [dir stringByAppendingPathComponent:bn];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [bp stringByAppendingPathComponent:@"Info.plist"]];
            if (info) [bundles addObject:@[ bp, info, @NO ]];
        }
    }

    // ② 系统 App（可选）
    if (includeSystem) {
        for (NSString *root in @[ @"/Applications", @"/System/Applications" ]) {
            for (NSString *bn in [fm contentsOfDirectoryAtPath:root error:NULL]) {
                if (![bn hasSuffix:@".app"]) continue;
                NSString *bp = [root stringByAppendingPathComponent:bn];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                      [bp stringByAppendingPathComponent:@"Info.plist"]];
                if (info) [bundles addObject:@[ bp, info, @YES ]];
            }
        }
    }

    NSMutableArray<SKToolApp *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    const CGFloat kIconSide = 40.0;

    for (NSArray *item in bundles) {
        @autoreleasepool {
            NSString *bp = item[0];
            NSDictionary *info = item[1];
            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
            if (selfID && [bid isEqualToString:selfID]) continue;
            if ([seen containsObject:bid]) continue;
            [seen addObject:bid];

            SKToolApp *a = [SKToolApp new];
            a.bundleID = bid;
            a.bundlePath = bp;
            a.isSystem = [item[2] boolValue];
            a.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"]
                     ?: bp.lastPathComponent.stringByDeletingPathExtension;
            a.version = info[@"CFBundleShortVersionString"] ?: @"1.0";
            a.icon = SKToolLoadIcon(bp, info, kIconSide);
            [out addObject:a];
        }
    }

    [out sortUsingComparator:^NSComparisonResult(SKToolApp *x, SKToolApp *y) {
        return [x.name localizedCaseInsensitiveCompare:y.name];
    }];
    return out;
}
