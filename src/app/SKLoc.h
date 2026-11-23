//
//  SKLoc.h
//  Blade — string lookup
//
//  Every user-facing string goes through here. Nothing is hardcoded in a
//  particular language: the value comes from <lang>.lproj/Localizable.strings
//  matching the device language, falling back to the development region.
//

#ifndef SK_LOC_H
#define SK_LOC_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define SKLoc(key)  NSLocalizedString((key), nil)

/// Monospaced font used across the console-style UI.
static inline UIFont *SKMono(CGFloat size, UIFontWeight weight) {
    UIFont *f = [UIFont monospacedSystemFontOfSize:size weight:weight];
    return f ?: [UIFont systemFontOfSize:size weight:weight];
}

#endif
