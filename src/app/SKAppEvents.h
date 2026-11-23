//
//  SKAppEvents.h
//  AppDump — cross-tab notifications
//

#ifndef SKAppEvents_h
#define SKAppEvents_h

#import <Foundation/Foundation.h>

// Exploit finished successfully: the app list may now be read.
FOUNDATION_EXPORT NSNotificationName const SKExploitDidSucceedNotification;

// One app finished dumping / extracting: badges and file lists are stale.
FOUNDATION_EXPORT NSNotificationName const SKDumpDidFinishNotification;

#endif /* SKAppEvents_h */
