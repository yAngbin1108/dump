//
//  SKLaraFileBrowser.h
//  AppDump — directory browser
//
//  Rebuilt in UIKit from the original's DirectoryView: a grouped list with an
//  SF Symbol per row, the app's UDID as a subtitle for bundles, a chevron for
//  directories, a search field in the navigation bar, a trailing menu (new
//  folder / sort / refresh) and a context menu per row.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SKLaraFileBrowser : UIViewController
- (instancetype)initWithPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
